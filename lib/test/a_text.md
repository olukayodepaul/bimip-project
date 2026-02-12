defmodule Queue.QueueLogImpl do
  @moduledoc """
  BimipLog — Production-grade append-only log.
  Optimized for O(1) fetching using physical bookmarks and sequential writes.
  Includes Poison Message skipping to prevent queue deadlocks.
  Sharded ETS for sparse index to reduce contention.
  """

  require Logger

  @base_dir "data/bimip"
  @index_granularity 50
  @segment_size_limit 104_857_600 # 100MB
  @entry_header_size 24
  @index_entry_size 20 # offset(8) + seg(4) + pos(8)
  @max_poison_retries 3
  @write_max_retries 3

  # ETS Table Names
  @num_index_shards 16
  @bookmark_cache :bimip_device_bookmarks
  @poison_tracker :bimip_poison_tracker

  # -------------------------------------------------------------------
  # Public API: Writing
  # -------------------------------------------------------------------
  def write(fd, partition_id, user, reply_to, type, payload_context, payload, message_id) do
    ensure_index_loaded(user, partition_id)

    with {:ok, %{seg: seg, next_offset: current_offset, do_rollover: do_rollover}} <-
           get_write_state_peek(user, partition_id) do
      ensure_first_segment(user, partition_id, seg)

      timestamp = DateTime.utc_now() |> DateTime.to_unix(:millisecond)
      offset_payload = Queue.Persist.build(%{payload: payload}, current_offset, reply_to, type, payload_context)

      case :file.position(fd, :cur) do
        {:ok, pos_before} ->
          record = %{
            peer_uid: message_id,
            device_id: payload.device_id,
            offset: current_offset,
            partition_id: partition_id,
            from: user,
            to: reply_to,
            payload: offset_payload,
            timestamp: timestamp
          }

          case write_log_entry(fd, record, record.device_id, current_offset) do
            :ok ->
              finalize_write_state(user, partition_id, seg, current_offset, pos_before, do_rollover)
              status = if do_rollover, do: :rollover, else: :ok
              {:ok, current_offset, status}

            {:error, reason} ->
              Logger.error("Failed to write to log for #{user}: #{inspect(reason)}")
              {:error, reason}
          end

        {:error, reason} -> {:error, reason}
      end
    end
  end

  # -------------------------------------------------------------------
  # Safe write with bookmark update
  # -------------------------------------------------------------------
  def safe_write(fd, partition_id, user, to, type, payload_context, payload, message_id, attempt \\ 1) do
    case write(fd, partition_id, user, to, type, payload_context, payload, message_id) do
      {:ok, offset, status} ->
        bookmark_key = {user, payload.device_id, partition_id}
        :ets.insert(@bookmark_cache, {bookmark_key, offset, 0})
        {:ok, offset, status}

      {:error, reason} ->
        if attempt < @write_max_retries and transient_error?(reason) do
          :timer.sleep(100 * attempt)
          safe_write(fd, partition_id, user, to, type, payload_context, payload, message_id, attempt + 1)
        else
          Logger.error("Write failed after #{attempt} attempts: #{inspect(reason)}")
          {:error, reason}
        end
    end
  end

  defp transient_error?(reason) do
    case reason do
      :eio -> true
      :eintr -> true
      :enoent -> true
      _ -> false
    end
  end

  # -------------------------------------------------------------------
  # Public API: Fetching
  # -------------------------------------------------------------------
  def fetch(user, device_id, to_device, partition_id, limit \\ 10) when limit > 0 do
    ensure_index_loaded(user, partition_id)
    bookmark_key = {user, device_id, partition_id}

    with :ok <- ensure_files_exist(user, partition_id),
         {:ok, commit_offset} <- get_commit_offset(user, device_id, partition_id),
         {:ok, current_seg} <- get_current_segment(user, partition_id),
         {:ok, first_seg} <- get_first_segment(user, partition_id) do

      target_offset = commit_offset + 1
      {start_seg, start_pos} = find_physical_start(user, partition_id, target_offset, bookmark_key, first_seg)

      range = if start_seg <= current_seg, do: start_seg..current_seg, else: current_seg..start_seg

      {messages_reversed, _final_seg, _final_pos} =
        Enum.reduce_while(range, {[], start_seg, start_pos}, fn seg, {acc, _, _} ->
          if length(acc) >= limit do
            {:halt, {acc, seg, 0}}
          else
            qfile = queue_file(user, partition_id, seg)
            seek = if seg == start_seg, do: start_pos, else: 0

            case read_from_file(qfile, seek, target_offset, device_id, limit - length(acc)) do
              {new_msgs_rev, last_byte_pos} ->
                total_acc = new_msgs_rev ++ acc
                if length(total_acc) >= limit,
                   do: {:halt, {total_acc, seg, last_byte_pos}},
                   else: {:cont, {total_acc, seg, last_byte_pos}}
            end
          end
        end)

      {:ok,
       %{
         messages: Enum.map(Enum.reverse(messages_reversed), &wrap_message(&1, user, to_device)),
         device_offset: commit_offset
       }}
    end
  end

  # -------------------------------------------------------------------
  # Physical bookmark logic
  # -------------------------------------------------------------------
  defp find_physical_start(user, partition_id, target_offset, bookmark_key, first_seg) do
    case :ets.lookup(@bookmark_cache, bookmark_key) do
      [{_, seg, pos}] when seg >= first_seg -> {seg, pos}
      _ ->
        case lookup_index({user, partition_id, target_offset}) do
          {:ok, {seg, pos}} -> {seg, pos}
          :not_found ->
            case prev_index({user, partition_id, target_offset}) do
              {:ok, {seg, pos}} -> {seg, pos}
              :not_found -> {first_seg, 0}
            end
        end
    end
  end

  # -------------------------------------------------------------------
  # File Helpers
  # -------------------------------------------------------------------
  defp read_from_file(path, seek, target, device_id, limit) do
    if File.exists?(path) do
      case File.open(path, [:read, :binary, :read_ahead]) do
        {:ok, fd} ->
          if seek > 0, do: :file.position(fd, seek)
          result = collect_until_limit(fd, target, device_id, limit, [])
          File.close(fd)
          result
        {:error, _} -> {[], 0}
      end
    else
      {[], 0}
    end
  end

  defp collect_until_limit(fd, target, device_id, limit, acc) when length(acc) < limit do
    case read_log_entry_selective(fd, target, device_id) do
      {:ok, msg} ->
        collect_until_limit(fd, target, device_id, limit, [msg | acc])
      :skip ->
        collect_until_limit(fd, target, device_id, limit, acc)
      {:corrupt, offset, size} ->
        if should_skip_poison?(offset) do
          Logger.error("CRITICAL: Skipping poison message at offset #{offset} (CRC Mismatch).")
          :file.position(fd, {:cur, size})
          collect_until_limit(fd, target, device_id, limit, acc)
        else
          {acc, get_current_pos(fd)}
        end
      _ ->
        {acc, get_current_pos(fd)}
    end
  end

  defp collect_until_limit(_fd, _target, _device_id, _limit, acc), do: {acc, 0}

  defp get_current_pos(fd) do
    {:ok, pos} = :file.position(fd, :cur)
    pos
  end

  # -------------------------------------------------------------------
  # Poison Tracking Logic
  # -------------------------------------------------------------------
  defp should_skip_poison?(offset) do
    count = :ets.update_counter(@poison_tracker, offset, {2, 1}, {offset, 0})
    if count >= @max_poison_retries do
      :ets.delete(@poison_tracker, offset)
      true
    else
      false
    end
  end

  # -------------------------------------------------------------------
  # Serialization Helpers
  # -------------------------------------------------------------------
  defp write_log_entry(fd, rec, device_id, offset) do
    data = :erlang.term_to_binary(rec, [:compressed])
    header = <<byte_size(data)::32, :erlang.crc32(data)::32, device_id::64, offset::64>>
    :file.write(fd, [header, data])
  end

  defp read_log_entry_selective(fd, target_offset, current_device_id) do
    case :file.read(fd, @entry_header_size) do
      {:ok, <<size::32, crc::32, sender_did::64, msg_off::64>>} ->
        if msg_off < target_offset or sender_did == current_device_id do
          :file.position(fd, {:cur, size})
          :skip
        else
          case :file.read(fd, size) do
            {:ok, bin} ->
              if :erlang.crc32(bin) == crc do
                {:ok, :erlang.binary_to_term(bin, [:safe])}
              else
                {:corrupt, msg_off, size}
              end
            _ -> :eof
          end
        end
      _ -> :eof
    end
  end

  # -------------------------------------------------------------------
  # ACK & Commit Offset Management
  # -------------------------------------------------------------------
  def advance_offset(user, device, partition, offset_or_range) do
    key = {user, device, partition}
    new_ranges = normalize_ranges(offset_or_range)

    :mnesia.transaction(fn ->
      commit = dirty_get(:commit_offsets, key, 0)
      pending = dirty_get(:pending_acks, key, [])
      merged = merge_and_sort_ranges(pending ++ new_ranges, commit)

      {new_commit, remaining} =
        case merged do
          [{s, e} | rest] when s == commit + 1 -> {e, rest}
          other -> {commit, other}
        end

      :mnesia.write({:commit_offsets, key, new_commit})
      :mnesia.write({:pending_acks, key, remaining})
      update_physical_bookmark(user, device, partition, new_commit)
      new_commit
    end)
  end

  defp update_physical_bookmark(user, device, partition, commit_offset) do
    case lookup_index({user, partition, commit_offset}) do
      {:ok, {seg, pos}} ->
        :ets.insert(@bookmark_cache, {{user, device, partition}, seg, pos})
      :not_found -> :ok
    end
  end

  defp merge_and_sort_ranges(ranges, commit) do
    ranges
    |> Enum.filter(fn {_, e} -> e > commit end)
    |> Enum.sort()
    |> Enum.reduce([], fn {s, e}, acc ->
      case acc do
        [] -> [{s, e}]
        [{ps, pe} | rest] -> if s <= pe + 1, do: [{ps, max(pe, e)} | rest], else: [{s, e}, {ps, pe} | rest]
      end
    end)
    |> Enum.reverse()
  end

  # -------------------------------------------------------------------
  # Index & Sharding Helpers
  # -------------------------------------------------------------------
  defp init_storage do
    Process.put(:ets_initialized, true)
    @idx_shards = Enum.map(0..(@num_index_shards - 1), fn i ->
      table_name = :"bimip_index_cache_#{i}"
      :ets.new(table_name, [:ordered_set, :public, read_concurrency: true, write_concurrency: true])
      table_name
    end)

    :ets.new(@bookmark_cache, [:named_table, :public, read_concurrency: true])
    :ets.new(@poison_tracker, [:named_table, :public, write_concurrency: true])
    Logger.info("Sharded ETS index tables initialized")
  end

  defp shard_for({user, pid}) do
    idx = :erlang.phash2({user, pid}, @num_index_shards)
    Enum.at(@idx_shards, idx)
  end

  defp insert_index({user, pid, offset}, seg, pos) do
    shard = shard_for({user, pid})
    :ets.insert(shard, {{user, pid, offset}, seg, pos})
  end

  defp lookup_index({user, pid, offset}) do
    shard = shard_for({user, pid})
    case :ets.lookup(shard, {user, pid, offset}) do
      [] -> :not_found
      [{_, seg, pos}] -> {:ok, {seg, pos}}
    end
  end

  defp prev_index({user, pid, offset}) do
    shard = shard_for({user, pid})
    case :ets.prev(shard, {user, pid, offset + 0.5}) do
      {^user, ^pid, off} ->
        [{_, seg, pos}] = :ets.lookup(shard, {user, pid, off})
        {:ok, {seg, pos}}
      _ -> :not_found
    end
  end

  # -------------------------------------------------------------------
  # Index loading
  # -------------------------------------------------------------------
  defp ensure_index_loaded(user, pid) do
    unless Process.get(:ets_initialized) do
      init_storage()
    end

    shard = shard_for({user, pid})
    if :ets.match(shard, {{user, pid, :_}, :_, :_}, 1) == :"$end_of_table" do
      load_index_into_cache(user, pid)
    end
  end

  defp load_index_into_cache(user, pid) do
    path = index_file(user, pid)
    if File.exists?(path) do
      File.stream!(path, [], @index_entry_size * 100)
      |> Stream.flat_map(fn bin -> split_binary_into_chunks(bin, @index_entry_size) end)
      |> Enum.each(fn <<off::64, seg::32, pos::64>> ->
        insert_index({user, pid, off}, seg, pos)
      end)
    end
  end

  defp split_binary_into_chunks(bin, size), do: for <<chunk::binary-size(size) <- bin>>, do: chunk

  # -------------------------------------------------------------------
  # Rollover & State Helpers
  # -------------------------------------------------------------------
  defp finalize_write_state(user, pid, seg, offset, pos, rollover) do
    if rollover, do: :mnesia.dirty_write({:current_segment, {user, pid}, seg + 1})
    if rem(offset, @index_granularity) == 0, do: append_index_file(user, pid, seg, offset, pos)
    :mnesia.dirty_write({:next_offsets, {user, pid}, offset + 1})
  end

  defp get_write_state_peek(user, partition_id) do
    key = {user, partition_id}
    curr_seg = dirty_get(:current_segment, key, 1)
    next_off = dirty_get(:next_offsets, key, 1)
    roll = case File.stat(queue_file(user, partition_id, curr_seg)) do
      {:ok, %{size: s}} -> s >= @segment_size_limit
      _ -> false
    end
    {:ok, %{seg: curr_seg, next_offset: next_off, do_rollover: roll}}
  end

  # -------------------------------------------------------------------
  # Helpers
  # -------------------------------------------------------------------
  defp normalize_ranges(input), do: List.wrap(input) |> Enum.map(fn
    %Range{first: s, last: e} -> {s, e}
    i when is_integer(i) -> {i, i}
  end)

  defp dirty_get(table, key, default) do
    case :mnesia.dirty_read(table, key) do
      [{_, _, val}] -> val
      _ -> default
    end
  end

  defp queue_file(u, p, s), do: Path.join([@base_dir, u, "queue_#{p}_#{s}.log"])
  defp index_file(u, p), do: Path.join([@base_dir, u, "index_#{p}.idx"])
  defp ensure_files_exist(u, _), do: File.mkdir_p(Path.join(@base_dir, u))
  defp get_commit_offset(u, d, p), do: {:ok, dirty_get(:commit_offsets, {u, d, p}, 0)}
  defp get_current_segment(u, p), do: {:ok, dirty_get(:current_segment, {u, p}, 1)}
  defp get_first_segment(u, p), do: {:ok, dirty_get(:first_segment, {u, p}, 1)}

  defp ensure_first_segment(u, p, seg) do
    if :mnesia.dirty_read(:first_segment, {u, p}) == [],
      do: :mnesia.dirty_write({:first_segment, {u, p}, seg})
  end

  defp wrap_message(%{payload: %Bimip.Message{} = payload}, eid, to_device) do
    %Bimip.Message{
      payload
      | to: %Bimip.Identity{
          payload.to
          | eid: eid,
            connection_resource_id: to_device
        },
        type: if(payload.from.eid == eid, do: 2, else: 3)
    }
  end

  defp append_index_file(u, p, seg, off, pos) do
    insert_index({u, p, off}, seg, pos)
    case :file.open(index_file(u, p), [:append, :binary, :raw, {:delayed_write, 65536, 1000}]) do
      {:ok, fd} ->
        :ok = :file.write(fd, <<off::64, seg::32, pos::64>>)
        :file.close(fd)
      _ -> :error
    end
  end

  def get_current_log_path(user, partition_id) do
    case get_current_segment(user, partition_id) do
      {:ok, seg} -> queue_file(user, partition_id, seg)
      _ -> nil
    end
  end
end





defmodule Queue.QueueLogImpl do
  # ... your existing code ...

  # ------------------------------------------------------------------
  # PUBLIC API
  # ------------------------------------------------------------------

  # Write message, now tracking writer device
  def write(partition_id, user, device_id, type, payload_ctx, payload, message_id) do
    shard = :erlang.phash2(user, @num_shards)
    buf = log_buffer(shard)

    if :ets.info(buf, :size) > @max_buffer_per_shard do
      {:error, :backpressure}
    else
      offset = :ets.update_counter(@user_offsets, {user, partition_id}, {2, 1}, {{user, partition_id}, 0})

      record = %{
        u: user,
        p: partition_id,
        off: offset,
        mid: message_id,
        writer_device: device_id,         # NEW: track which device wrote it
        data: Queue.Persist.build(payload, offset, type, payload_ctx),
        ts: System.system_time(:second)
      }

      :ets.insert(buf, {shard, offset, record})
      {:ok, offset}
    end
  end

  # Fetch messages skipping ones written by this device
  def fetch_for_device(user, partition_id, device_id, offset) do
    shard = :erlang.phash2(user, @num_shards)

    case :ets.match_object(log_buffer(shard), {shard, offset, %{u: user, p: partition_id}}) do
      [{_, _, rec}] ->
        if rec.writer_device == device_id do
          {:ok, []} # skip own message
        else
          {:ok, [rec.data]}
        end

      [] ->
        case :ets.lookup(idx_cache(shard), {user, partition_id, offset}) do
          [{{^user, ^partition_id, ^offset}, {seg_base, pos}}] ->
            with {:ok, rec} <- read_from_disk(shard, seg_base, pos) do
              # assume rec has writer_device stored in it
              if Map.get(rec, :writer_device) == device_id do
                {:ok, []} # skip own message
              else
                {:ok, [rec.data]}
              end
            else
              _ -> {:error, :read_failed}
            end

          [] -> {:error, :not_found}
        end
    end
  end
end

defmodule Queue.DeviceBookmark do
  @moduledoc """
  Tracks per-device offsets (bookmarks) for V6 queue.
  Uses ETS for fast in-memory access and Mnesia for durability.
  """

  @table :device_bookmarks       # Mnesia table
  @cache :device_bookmarks_cache # ETS cache

  # ------------------------------------------------------------------
  # Startup (initialize Mnesia + ETS)
  # ------------------------------------------------------------------
  def startup do
    :mnesia.start()

    unless table_exists?(@table) do
      :mnesia.create_table(@table, [
        {:attributes, [:device_id, :user, :partition_id, :offset]},
        {:type, :set},
        {:disc_copies, [node()]},
        {:index, [:user, :partition_id]}
      ])
    end

    unless :ets.info(@cache) do
      :ets.new(@cache, [:named_table, :public, :set, {:read_concurrency, true}, {:write_concurrency, true}])
    end

    load_cache_from_mnesia()
    :ok
  end

  defp table_exists?(table) do
    case :mnesia.table_info(table, :attributes) do
      [_ | _] -> true
      _ -> false
    rescue
      _ -> false
    end
  end

  defp load_cache_from_mnesia do
    :mnesia.transaction(fn ->
      :mnesia.match_object({@table, :_, :_, :_, :_})
    end)
    |> case do
      {:atomic, records} ->
        Enum.each(records, fn {@table, device_id, user, partition_id, offset} ->
          :ets.insert(@cache, {{device_id, user, partition_id}, offset})
        end)
      _ -> :ok
    end
  end

  # ------------------------------------------------------------------
  # Get last offset
  # ------------------------------------------------------------------
  def get(device_id, user, partition_id) do
    case :ets.lookup(@cache, {device_id, user, partition_id}) do
      [{{^device_id, ^user, ^partition_id}, offset}] -> offset
      [] -> 0
    end
  end

  # ------------------------------------------------------------------
  # Set offset (overwrite)
  # ------------------------------------------------------------------
  def set(device_id, user, partition_id, offset) do
    :ets.insert(@cache, {{device_id, user, partition_id}, offset})
    :mnesia.transaction(fn ->
      :mnesia.write({@table, device_id, user, partition_id, offset})
    end)
  end

  # ------------------------------------------------------------------
  # Advance offset if new_offset > current
  # ------------------------------------------------------------------
  def advance(device_id, user, partition_id, new_offset) do
    current = get(device_id, user, partition_id)

    if new_offset > current do
      set(device_id, user, partition_id, new_offset)
    else
      :ok
    end
  end
end
