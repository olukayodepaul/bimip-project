defmodule Queue.QueueLogImpl do
  @moduledoc """
  BimipLog — Production-grade append-only log with:
    - Sharded ETS index cache
    - LRU eviction to handle millions of users/messages
    - Sparse index for memory efficiency
    - File Descriptor (FD) pooling with LRU eviction for read operations
  """

  require Logger

  @base_dir "data/bimip"
  @index_granularity 50
  @segment_size_limit 104_857_600 # 100MB
  @entry_header_size 24
  @index_entry_size 20
  @max_poison_retries 3
  @write_max_retries 3
  @num_index_shards 16
  @lru_eviction_interval :timer.seconds(60)
  @lru_entry_age_limit :timer.minutes(10)
  @max_open_files 1024

  @bookmark_cache :bimip_device_bookmarks
  @poison_tracker :bimip_poison_tracker
  @access_times :bimip_index_access_times
  @fd_pool :bimip_fd_pool

  # -------------------------------------------------------------------
  # ETS Startup
  # -------------------------------------------------------------------
  def __ets_startup__ do
    for i <- 0..(@num_index_shards - 1) do
      name = shard_name(i)
      if :ets.info(name) == :undefined do
        :ets.new(name, [:named_table, :ordered_set, :public,
                        read_concurrency: true, write_concurrency: true])
      end
    end

    tables = [@bookmark_cache, @poison_tracker, @access_times, @fd_pool]
    Enum.each(tables, fn table ->
      if :ets.info(table) == :undefined do
        :ets.new(table, [:named_table, :public, read_concurrency: true, write_concurrency: true])
      end
    end)

    Logger.info("Sharded ETS + LRU + FD Pool initialized")
  end

  def start_lru_eviction do
    spawn(fn -> lru_loop() end)
  end

  defp lru_loop do
    :timer.sleep(@lru_eviction_interval)
    evict_old_entries()
    lru_loop()
  end

  # -------------------------------------------------------------------
  # LRU Helpers
  # -------------------------------------------------------------------
  defp record_access(key) do
    now = System.monotonic_time(:millisecond)
    :ets.insert(@access_times, {key, now})
  end

  defp evict_old_entries do
    threshold = System.monotonic_time(:millisecond) - @lru_entry_age_limit
    match_spec = [{{:"$1", :"$2"}, [{:<, :"$2", threshold}], [:"$1"]}]
    do_evict_batch(:ets.select(@access_times, match_spec, 500))
  end

  defp do_evict_batch(:"$end_of_table"), do: :ok
  defp do_evict_batch({keys, continuation}) do
    Enum.each(keys, fn {user, pid, _} = key ->
      shard = shard_for({user, pid})
      :ets.delete(shard, key)
      :ets.delete(@access_times, key)
    end)
    do_evict_batch(:ets.select(continuation))
  end

  # -------------------------------------------------------------------
  # Shard Helpers
  # -------------------------------------------------------------------
  defp shard_name(idx), do: :"bimip_index_cache_#{idx}"
  defp shard_for({user, pid}), do: shard_name(:erlang.phash2({user, pid}, @num_index_shards))

  # -------------------------------------------------------------------
  # Index access
  # -------------------------------------------------------------------
  defp lookup_index({user, pid, offset}) do
    shard = shard_for({user, pid})
    case :ets.lookup(shard, {user, pid, offset}) do
      [{_, seg, pos}] ->
        record_access({user, pid, offset})
        {:ok, {seg, pos}}
      _ -> :not_found
    end
  end

  defp prev_index({user, pid, offset}) do
    shard = shard_for({user, pid})
    case :ets.prev(shard, {user, pid, offset + 0.5}) do
      {^user, ^pid, _} = key ->
        case :ets.lookup(shard, key) do
          [{_, seg, pos}] ->
             record_access(key)
             {:ok, {seg, pos}}
          _ -> :not_found
        end
      _ -> :not_found
    end
  end

  # -------------------------------------------------------------------
  # Public API: Writing (UPDATED to accept index_fd)
  # -------------------------------------------------------------------
  def write(fd, index_fd, partition_id, user, reply_to, type, payload_context, payload, message_id) do
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

          case write_log_entry(fd, record) do
            :ok ->
              # Pass index_fd here
              finalize_write_state(index_fd, user, partition_id, seg, current_offset, pos_before, do_rollover)
              {:ok, current_offset, if(do_rollover, do: :rollover, else: :ok)}

            {:error, reason} ->
              Logger.error("Write error: #{inspect(reason)}")
              {:error, reason}
          end

        {:error, reason} -> {:error, reason}
      end
    end
  end

  # This wrapper needs to be updated to pass the index_fd through
  def safe_write(fd, index_fd, partition_id, user, to, type, payload_context, payload, message_id, attempt \\ 1) do
    case write(fd, index_fd, partition_id, user, to, type, payload_context, payload, message_id) do
      {:ok, offset, status} ->
        {:ok, offset, status}

      {:error, reason} ->
        cond do
          fatal_error?(reason) ->
            Logger.critical("FATAL WRITE ERROR: #{inspect(reason)}. Halting write operations for #{user}.")
            {:error, {:fatal_storage_error, reason}}

          attempt < @write_max_retries and transient_error?(reason) ->
            wait_time = :math.pow(attempt, 2) |> round() |> Kernel.*(100)
            Logger.warn("Transient write error: #{inspect(reason)}. Retry #{attempt}/#{@write_max_retries} in #{wait_time}ms")

            :timer.sleep(wait_time)
            safe_write(fd, index_fd, partition_id, user, to, type, payload_context, payload, message_id, attempt + 1)

          true ->
            Logger.error("Write failed after #{attempt} attempts. Final reason: #{inspect(reason)}")
            {:error, reason}
        end
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

      {messages_reversed, _, _} =
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

      {:ok, %{
         messages: Enum.map(Enum.reverse(messages_reversed), &wrap_message(&1, user, to_device)),
         device_offset: commit_offset
      }}
    end
  end

  # -------------------------------------------------------------------
  # ACK & Offset Management
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
      :not_found ->
        case prev_index({user, partition, commit_offset}) do
          {:ok, {seg, pos}} -> :ets.insert(@bookmark_cache, {{user, device, partition}, seg, pos})
          :not_found -> :ok
        end
    end
  end

  # -------------------------------------------------------------------
  # Internal File & Record Helpers
  # -------------------------------------------------------------------
  defp queue_file(u, p, s), do: Path.join([@base_dir, u, "queue_#{p}_#{s}.log"])
  defp index_file(u, p), do: Path.join([@base_dir, u, "index_#{p}.idx"])
  defp ensure_files_exist(u, _), do: File.mkdir_p(Path.join(@base_dir, u))

  defp dirty_get(t, k, d) do
    case :mnesia.dirty_read(t, k) do
      [{_, _, v}] -> v
      _ -> d
    end
  end

  defp transient_error?(reason) do
    reason in [:eio, :eintr, :ebusy, :eagain]
  end

  defp fatal_error?(reason) do
    reason in [:enospc, :eacces, :eperm, :enotdir, :eisdir]
  end

  defp normalize_ranges(input), do: List.wrap(input) |> Enum.map(fn %Range{first: s, last: e} -> {s, e}; i -> {i, i} end)

  defp write_log_entry(fd, rec) do
    data = :erlang.term_to_binary(rec, [:compressed])
    header = <<byte_size(data)::32, :erlang.crc32(data)::32, rec.device_id::64, rec.offset::64>>
    :file.write(fd, [header, data])
  end

  defp read_from_file(path, seek, target, device_id, limit) do
    case get_fd(path) do
      {:ok, fd} ->
        {:ok, _} = :file.position(fd, seek)
        collect_until_limit(fd, target, device_id, limit, [])
      {:error, _} ->
        {[], 0}
    end
  end

  defp collect_until_limit(fd, target, device_id, limit, acc) when length(acc) < limit do
    case read_log_entry_selective(fd, target, device_id) do
      {:ok, msg} -> collect_until_limit(fd, target, device_id, limit, [msg | acc])
      :skip -> collect_until_limit(fd, target, device_id, limit, acc)
      {:corrupt, offset, size} ->
        if should_skip_poison?(offset) do
          :file.position(fd, {:cur, size})
          collect_until_limit(fd, target, device_id, limit, acc)
        else
          {acc, get_current_pos(fd)}
        end
      _ -> {acc, get_current_pos(fd)}
    end
  end
  defp collect_until_limit(_fd, _target, _device_id, _limit, acc), do: {acc, 0}

  defp read_log_entry_selective(fd, target_offset, current_device_id) do
    case :file.read(fd, @entry_header_size) do
      {:ok, <<size::32, crc::32, sender_did::64, msg_off::64>>} ->
        if msg_off < target_offset or sender_did == current_device_id do
          :file.position(fd, {:cur, size})
          :skip
        else
          case :file.read(fd, size) do
            {:ok, bin} ->
              if :erlang.crc32(bin) == crc, do: {:ok, :erlang.binary_to_term(bin, [:safe])}, else: {:corrupt, msg_off, size}
            _ -> :eof
          end
        end
      _ -> :eof
    end
  end

  defp get_current_pos(fd) do
    case :file.position(fd, :cur) do
      {:ok, p} -> p
      _ -> 0
    end
  end

  # -------------------------------------------------------------------
  # Index Management
  # -------------------------------------------------------------------
  defp ensure_index_loaded(user, pid) do
    unless Process.get(:ets_initialized) do
      __ets_startup__()
      Process.put(:ets_initialized, true)
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
      |> Stream.flat_map(fn bin -> for <<chunk::binary-size(@index_entry_size) <- bin>>, do: chunk end)
      |> Enum.each(fn <<off::64, seg::32, pos::64>> ->
        :ets.insert(shard_for({user, pid}), {{user, pid, off}, seg, pos})
      end)
    end
  end

  # This is now only used as a fallback if you aren't using the FD-per-process model
  defp append_index_file(u, p, seg, off, pos) do
    case :file.open(index_file(u, p), [:append, :binary, :raw, {:delayed_write, 65536, 1000}]) do
      {:ok, fd} ->
        :file.write(fd, <<off::64, seg::32, pos::64>>)
        :file.close(fd)
      _ -> :error
    end
  end

  # -------------------------------------------------------------------
  # State Peeking & Bookkeeping
  # -------------------------------------------------------------------
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

  defp ensure_first_segment(u, p, seg) do
    if :mnesia.dirty_read(:first_segment, {u, p}) == [] do
      :mnesia.dirty_write({:first_segment, {u, p}, seg})
    end
  end

  defp should_skip_poison?(offset) do
    count = :ets.update_counter(@poison_tracker, offset, {2, 1}, {offset, 0})
    if count >= @max_poison_retries do
      :ets.delete(@poison_tracker, offset)
      true
    else
      false
    end
  end

  defp wrap_message(%{payload: %Bimip.Message{} = payload}, eid, to_device) do
    %Bimip.Message{payload | to: %Bimip.Identity{payload.to | eid: eid, connection_resource_id: to_device}, type: if(payload.from.eid == eid, do: 2, else: 3)}
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

  # UPDATED to use index_fd
  defp finalize_write_state(index_fd, user, pid, seg, offset, pos, rollover) do
    try do
      if rollover, do: :mnesia.dirty_write({:current_segment, {user, pid}, seg + 1})

      if rem(offset, @index_granularity) == 0 do
        shard = shard_for({user, pid})
        :ets.insert(shard, {{user, pid, offset}, seg, pos})

        # WRITE directly to the open handle
        :file.write(index_fd, <<offset::64, seg::32, pos::64>>)

        record_access({user, pid, offset})
      end

      :mnesia.dirty_write({:next_offsets, {user, pid}, offset + 1})
    rescue
      e ->
        Logger.error("Bookkeeping failed for #{user} at offset #{offset}: #{inspect(e)}")
    end
  end

  # -------------------------------------------------------------------
  # Public Getter API
  # -------------------------------------------------------------------
  def get_current_log_path(user, partition_id) do
    case dirty_get(:current_segment, {user, partition_id}, 1) do
      seg -> queue_file(user, partition_id, seg)
    end
  end

  def get_commit_offset(u, d, p), do: {:ok, dirty_get(:commit_offsets, {u, d, p}, 0)}
  def get_current_segment(u, p), do: {:ok, dirty_get(:current_segment, {u, p}, 1)}
  def get_first_segment(u, p), do: {:ok, dirty_get(:first_segment, {u, p}, 1)}

  # Accessor for index file path
  def index_file_path(u, p), do: index_file(u, p)

  # -------------------------------------------------------------------
  # File Descriptor Pool
  # -------------------------------------------------------------------

  def init_fd_pool do
    if :ets.info(@fd_pool) == :undefined do
      :ets.new(@fd_pool, [:named_table, :public, :set, write_concurrency: true])
    end
  end

  defp get_fd(path) do
    case :ets.lookup(@fd_pool, path) do
      [{^path, fd, last_access}] ->
        :ets.insert(@fd_pool, {path, fd, System.monotonic_time(:millisecond)})
        {:ok, fd}

      [] ->
        open_file_limited(path)
    end
  end

  defp open_file_limited(path) do
    open_count = :ets.info(@fd_pool, :size)
    if open_count >= @max_open_files do
      evict_lru_fd()
    end

    case File.open(path, [:read, :binary, :read_ahead]) do
      {:ok, fd} ->
        :ets.insert(@fd_pool, {path, fd, System.monotonic_time(:millisecond)})
        {:ok, fd}
      {:error, reason} ->
        Logger.error("Failed to open file #{path}: #{inspect(reason)}")
        {:error, reason}
    end
  end

  defp evict_lru_fd do
    [{path, fd, _}] =
      :ets.tab2list(@fd_pool)
      |> Enum.sort_by(fn {_, _, ts} -> ts end)
      |> Enum.take(1)

    :file.close(fd)
    :ets.delete(@fd_pool, path)
  end

  defp close_all_fds do
    for {_, fd, _} <- :ets.tab2list(@fd_pool) do
      :file.close(fd)
    end
    :ets.delete(@fd_pool)
  end
end
