defmodule Queue.QueueLogImpl do
  @moduledoc """
  BimipLog v10.8 — Fixed Stride logic by persisting user_counts in ETS.
  Sharding applied to Checkpoints, User Offsets, and Segment Counts.
  """
  use GenServer
  require Logger

  # ------------------------------------------------------------------
  # CONFIG
  # ------------------------------------------------------------------
  @base_dir "data/bimip"
  @num_shards 64
  @header_size 21
  @flush_interval 60_000
  @max_messages_per_seg 20
  @user_stride 10
  @max_buffer_per_shard 10_000_000

  @checkpoints_prefix :bimip_segment_checkpoints_
  @user_offsets_prefix :bimip_user_offsets_
  @user_segment_counts_prefix :bimip_user_segment_counts_
  @idx_cache_prefix :"bimip_idx_"
  @log_buffer_prefix :"bimip_buf_"
  @stable_limit 5_000
  @flush_state :flush_state

  # ------------------------------------------------------------------
  # PUBLIC API
  # ------------------------------------------------------------------

  def start_link(shard), do: GenServer.start_link(__MODULE__, shard, name: worker_name(shard))

  def __startup__ do

    if :ets.info(@flush_state) == :undefined do
      :ets.new(@flush_state, [
        :named_table,
        :public,
        :set,
        {:write_concurrency, true},
        {:read_concurrency, true}
      ])
    end

    for s <- 0..(@num_shards - 1) do
      if :ets.info(log_buffer(s)) == :undefined, do: :ets.new(log_buffer(s), [:named_table, :public, :set, {:write_concurrency, true}, {:read_concurrency, true}])
      if :ets.info(idx_cache(s)) == :undefined, do: :ets.new(idx_cache(s), [:named_table, :public, :set, {:read_concurrency, true}])

      if :ets.info(user_offsets_tab(s)) == :undefined do
        :ets.new(user_offsets_tab(s), [:named_table, :public, :set, {:write_concurrency, true}])
        # Initialize shard_offset and last_shard_offset
        :ets.insert(user_offsets_tab(s), {{:shard_offset, s}, 0})
        :ets.insert(user_offsets_tab(s), {{:last_shard_offset, s}, 0})
      end

      if :ets.info(checkpoints_tab(s)) == :undefined, do: :ets.new(checkpoints_tab(s), [:named_table, :public, :set, {:read_concurrency, true}])
      if :ets.info(user_segment_counts_tab(s)) == :undefined, do: :ets.new(user_segment_counts_tab(s), [:named_table, :public, :set, {:write_concurrency, true}])
    end
    :ok
  end

  def write(partition_id, sender_uid, recipient_uid, device_id, type, payload_ctx, payload, message_id, ts) do
    shard = :erlang.phash2(recipient_uid, @num_shards)
    buf = log_buffer(shard)
    u_offsets = user_offsets_tab(shard)

    if :ets.info(buf, :size) > @max_buffer_per_shard do
      {:error, :backpressure}
    else

      offset = :ets.update_counter(u_offsets, {recipient_uid, partition_id}, {2, 1}, {{recipient_uid, partition_id}, 0})
      data = Queue.Persist.build(%{payload: payload}, offset, recipient_uid, type, payload_ctx)
      shard_offset = :ets.update_counter(u_offsets,{:shard_offset, shard},  {2, 1}, {{:shard_offset, shard}, 0})

      record = %{
        u: recipient_uid,
        s: sender_uid,
        p: partition_id,
        off: offset,
        mid: message_id,
        msg_count: shard_offset,
        writer_device: to_string(device_id),
        bin: :erlang.term_to_binary(data),
        ts: ts
      }

      :ets.insert(buf, {shard_offset, {shard, offset, record}})
      {:ok, offset}
    end
  end

  def fetch_batch(user, partition_id, device_id, batch_size \\ 50) do
    shard = :erlang.phash2(user, @num_shards)
    GenServer.call(worker_name(shard), {:fetch, user, partition_id, to_string(device_id), batch_size}, 15_000)
  end

  # ------------------------------------------------------------------
  # GENSERVER HANDLERS
  # ------------------------------------------------------------------
  @impl true
  def init(shard) do
    shard_dir = Path.join(@base_dir, "#{shard}")
    File.mkdir_p!(shard_dir)
    File.mkdir_p!("data/device_bookmarks")

    bin_path = Path.join("data/device_bookmarks", "#{shard}.bin")

    manifest = load_manifest(shard)
    base = manifest.active_base
    ts = manifest.active_ts
    global_offset = manifest.msg_count

    u_offsets = user_offsets_tab(shard)
    :ets.insert(u_offsets, {{:shard_offset, shard}, global_offset})
    :ets.insert(u_offsets, {{:last_shard_offset, shard}, global_offset})

    # derive relative segment count (0-20) from global offset
    recovered_msg_count = if global_offset >= base, do: (global_offset - base) + 1, else: 0

    recover_user_stride_counts_to_ets(shard, base)

    log_path = Path.join(shard_dir, "#{shard}_#{base}_#{ts}.log")
    idx_path = Path.join(shard_dir, "#{shard}_#{base}_#{ts}.idx")

    {:ok, log_fd} = :file.open(log_path, [:append, :raw, :binary, :read, :delayed_write])
    {:ok, idx_fd} = :file.open(idx_path, [:append, :raw, :binary, :read, :write])

    # 🚀 Seed ETS manifest snapshot so other processes/rotation can see it
    :ets.insert(user_offsets_tab(shard), {:manifest_snapshot, manifest})

    if not manifest.exists, do: write_manifest(shard, manifest)

    {:ok, actual_pos} = :file.position(log_fd, :cur)

    state = %{
      shard: shard, shard_dir: shard_dir,
      log_fd: log_fd, idx_fd: idx_fd,
      current_size: actual_pos,
      msg_count: recovered_msg_count, # Local file counter
      active_base: base, active_ts: ts
    }

    schedule_flush()
    if !File.exists?(bin_path), do: snapshot_bin(state)

    {:ok, state}
  end

  defp recover_user_stride_counts_to_ets(shard, active_base) do
    u_offsets = user_offsets_tab(shard)
    u_counts = user_segment_counts_tab(shard)

    :ets.tab2list(u_offsets)
    |> Enum.each(fn {{user, _partition}, off} ->
      count_in_seg = off - (active_base - 1)
      final_count = if count_in_seg < 0, do: 0, else: count_in_seg
      :ets.insert(u_counts, {user, final_count})
    end)
  end

  @impl true
  defp perform_flush(state) do
    buf = log_buffer(state.shard)
    drain_buf(buf, state)
  end

  @impl true
  def handle_call({:fetch, user, p, device_id, batch_size}, _from, state) do
    log_off = Queue.DeviceBookmark.get(device_id, user)
    cache = :"device_bookmarks_cache_#{state.shard}"

    seg_id = case :ets.lookup(cache, user) do
      [{^user, %{"__anchor__" => {seg, _}}}] ->
         [base_str | _] = String.split(seg, "_")
         String.to_integer(base_str)
      _ -> state.active_base
    end

    gate_off = if log_off > 0, do: log_off - rem(log_off - 1, @user_stride), else: 0

    {actual_seg, actual_phys} = case :ets.lookup(idx_cache(state.shard), {user, p, gate_off}) do
      [{_, {s, pos}}] -> {s, pos}
      _ -> {seg_id, 0}
    end

    {:ok, disk_results} = stream_messages(state, user, p, actual_seg, actual_phys, batch_size, [], device_id)
    filtered = Enum.filter(disk_results, fn msg -> msg.off > log_off end)
    {:reply, {:ok, filtered}, state}
  end

  defp perform_flush(state) do
    buf = log_buffer(state.shard)
    # Start the stable drain process
    drain_buf(buf, state)
  end

  defp process_batch(state, items, depth \\ 0)
  defp process_batch(state, [], _depth), do: state

  defp process_batch(state, items, depth) when depth > 500 do
    Logger.error("Flush recursion too deep. Shard: #{state.shard}")
    state
  end

defp process_batch(state, items, depth) do
    space_left = @max_messages_per_seg - state.msg_count
    {to_write, leftovers} = Enum.split(items, space_left)
    u_counts = user_segment_counts_tab(state.shard)

    if to_write != [] do
      {bin_io, idx_io, final_count, final_bytes, updates, latest_map} =
        Enum.reduce(to_write, {[], [], state.msg_count, state.current_size, [], %{}},
          fn {{_s, _off, _seq}, rec}, {b_acc, i_acc, curr_idx, curr_phys, upd, l_map} ->
            {bin_packet, p_size} = encode_packet(rec, rec.off, state)
            u_count = :ets.update_counter(u_counts, rec.u, {2, 1}, {rec.u, 0})

            {new_i_acc, new_upd} =
              if rem(u_count - 1, @user_stride) == 0 do
                u_bin = to_string(rec.u)
                idx_entry = <<byte_size(u_bin)::16, u_bin::binary, rec.p::32, rec.off::64, state.active_base::64, curr_phys::64>>
                :ets.insert(idx_cache(state.shard), {{rec.u, rec.p, rec.off}, {state.active_base, curr_phys}})
                {[i_acc | idx_entry], [{rec.u, rec.off} | upd]}
              else
                {i_acc, upd}
              end

            {[b_acc | bin_packet], new_i_acc, curr_idx + 1, curr_phys + p_size, new_upd, Map.put(l_map, rec.u, rec.off)}
          end)

      {_last_tag, last_record} = List.last(to_write)
      last_batch_shard_offset = last_record.msg_count

      # 🚀 Sync Manifest with the actual Global Offset
      u_offsets = user_offsets_tab(state.shard)
      manifest = case :ets.lookup(u_offsets, :manifest_snapshot) do
        [{:manifest_snapshot, m}] -> m
        [] -> load_manifest(state.shard)
      end

      updated_manifest = %{manifest | msg_count: last_batch_shard_offset}
      write_manifest(state.shard, updated_manifest)
      :ets.insert(u_offsets, {:manifest_snapshot, updated_manifest})

      :file.write(state.log_fd, bin_io)
      :file.write(state.idx_fd, idx_io)

      global_max_offset = latest_map |> Map.values() |> Enum.max()
      Enum.each(latest_map, fn {u, off} -> Queue.DeviceBookmark.mark_anchor(u, "#{state.active_base}_#{state.active_ts}", global_max_offset) end)
      Enum.each(updates, fn {u, off} -> Queue.DeviceBookmark.mark_position(u, "#{state.active_base}_#{state.active_ts}", off) end)

      new_state = %{state | msg_count: final_count, current_size: final_bytes}

      if new_state.msg_count >= @max_messages_per_seg do
        snapshot_bin(new_state)
        rotated_state = rotate_segment(new_state)
        process_batch(rotated_state, leftovers, depth + 1)
      else
        process_batch(new_state, leftovers, depth + 1)
      end
    else
      state
    end
  end

  defp snapshot_bin(state) do
    cache = :"device_bookmarks_cache_#{state.shard}"
    bin_path = Path.join("data/device_bookmarks", "#{state.shard}.bin")

    existing_map = if File.exists?(bin_path) do
      case File.read(bin_path) do
        {:ok, b} when b != <<>> ->
          try do
            term = :erlang.binary_to_term(b)
            if is_list(term), do: Map.new(term), else: term
          rescue _ -> %{} end
        _ -> %{}
      end
    else
      %{}
    end

    hot_map = if :ets.info(cache) != :undefined, do: :ets.tab2list(cache) |> Map.new(), else: %{}

    merged_data = Map.merge(existing_map, hot_map)
    bin = :erlang.term_to_binary(merged_data, [:compressed])
    Queue.FDPoolShard.atomic_snapshot(state.shard, bin_path, bin)
    :ok
  end

  defp encode_packet(rec, offset, state) do
    u_bin = to_string(rec.u)
    d_bin = to_string(rec.writer_device)
    packet = [
      <<0xEE, byte_size(rec.bin)::32, :erlang.crc32(rec.bin)::32, byte_size(u_bin)::16, byte_size(d_bin)::16, rec.ts::64>>,
      u_bin, d_bin, <<rec.p::32, offset::64>>, rec.bin
    ]
    {packet, IO.iodata_length(packet)}
  end

defp rotate_segment(state) do
    # 1. Calculate new coordinates
    new_base = state.active_base + state.msg_count
    new_ts = System.system_time(:second)

    # 2. Close old files
    :file.close(state.log_fd)
    :file.close(state.idx_fd)

    # 3. Pre-create and Sync NEW Segment Files
    l_path = Path.join(state.shard_dir, "#{state.shard}_#{new_base}_#{new_ts}.log")
    i_path = Path.join(state.shard_dir, "#{state.shard}_#{new_base}_#{new_ts}.idx")

    {:ok, tmp_l} = :file.open(l_path, [:write, :raw, :binary])
    :file.datasync(tmp_l)
    :file.close(tmp_l)

    {:ok, tmp_i} = :file.open(i_path, [:write, :raw, :binary])
    :file.datasync(tmp_i)
    :file.close(tmp_i)

    # POSIX directory sync
    case :file.open(state.shard_dir, [:read, :raw]) do
      {:ok, dir_fd} ->
        :file.datasync(dir_fd)
        :file.close(dir_fd)
      _ -> :ok
    end

    # 4. Atomic Manifest Flip
    u_offsets = user_offsets_tab(state.shard)

    # Get the latest global offset from ETS
    current_global_offset = :ets.lookup_element(u_offsets, {:shard_offset, state.shard}, 2)

    # 🚀 FIX: Get manifest from ETS if available, otherwise disk
    manifest = case :ets.lookup(u_offsets, :manifest_snapshot) do
      [{:manifest_snapshot, m}] -> m
      [] -> load_manifest(state.shard)
    end

    expired_key = "#{state.active_base}_#{state.active_ts}"

    updated_manifest = %{
      active_base: new_base,
      active_ts: new_ts,
      msg_count: current_global_offset, # Preserve the global truth
      expired: Map.put(manifest.expired, expired_key, new_ts)
    }

    # 🚀 FIX: Write to Disk AND Update the ETS Snapshot
    write_manifest(state.shard, updated_manifest)
    :ets.insert(u_offsets, {:manifest_snapshot, updated_manifest})

    # 5. Open handles for the new state
    {:ok, l} = :file.open(l_path, [:append, :raw, :binary, :read, :delayed_write])
    {:ok, i} = :file.open(i_path, [:append, :raw, :binary, :read, :write])

    # Clear segment-specific user counts for the new file
    :ets.delete_all_objects(user_segment_counts_tab(state.shard))

    # Reset msg_count to 0 because this is a NEW file
    %{state | log_fd: l, idx_fd: i, active_base: new_base, active_ts: new_ts, current_size: 0, msg_count: 0}
  end

  defp write_manifest(shard, manifest_data) do
    shard_dir = Path.join(@base_dir, "#{shard}")
    path = Path.join(shard_dir, "#{shard}.manifest")
    tmp_path = path <> ".tmp"

    storage_map = Map.drop(manifest_data, [:exists])
    binary = :erlang.term_to_binary(storage_map)

    # Open, Write, Sync, Close
    {:ok, fd} = :file.open(tmp_path, [:write, :raw, :binary])
    :file.write(fd, binary)
    :file.datasync(fd) # <--- The Hardware Commit
    :file.close(fd)

    File.rename!(tmp_path, path)
  end

  defp read_from_disk(state, base, pos) do
    case Path.wildcard(Path.join(state.shard_dir, "#{state.shard}_#{base}_*.log")) do
      [path | _] ->
        case Queue.FDPoolShard.pread(state.shard, path, pos, @header_size) do
          {:ok, <<0xEE, size::32, _crc::32, ulen::16, dlen::16, _ts::64>>} ->
            case Queue.FDPoolShard.pread(state.shard, path, pos + @header_size, ulen + dlen + 12 + size) do
              {:ok, <<u::binary-size(ulen), d::binary-size(dlen), p::32, off::64, body::binary>>} ->
                {:ok, %{u: u, writer_device: d, p: p, off: off, data: :erlang.binary_to_term(body, [:safe])}, pos + @header_size + ulen + dlen + 12 + size}
              _ -> {:error, :body_failed}
            end
          :eof -> {:error, :eof}
          _ -> {:error, :read_failed}
        end
      [] -> {:error, :file_not_found}
    end
  end

  defp stream_messages(state, user, p, seg_id, phys_pos, count, acc, device_id) do
    if count <= 0 do
      {:ok, Enum.reverse(acc)}
    else
      case read_from_disk(state, seg_id, phys_pos) do
        {:ok, rec, next_pos} ->
          if rec.u == to_string(user) and rec.p == p and rec.writer_device != device_id do
            stream_messages(state, user, p, seg_id, next_pos, count - 1, [rec.data | acc], device_id)
          else
            stream_messages(state, user, p, seg_id, next_pos, count, acc, device_id)
          end
        {:error, :eof} ->
          case find_next_segment(state, seg_id) do
            {:ok, next} -> stream_messages(state, user, p, next, 0, count, acc, device_id)
            _ -> {:ok, Enum.reverse(acc)}
          end
        _ -> {:ok, Enum.reverse(acc)}
      end
    end
  end

  defp find_next_segment(state, current_base) do
    files = Path.wildcard(Path.join(state.shard_dir, "#{state.shard}_*.log"))
    bases = Enum.reduce(files, [], fn f, acc ->
      filename = Path.basename(f, ".log")
      parts = String.split(filename, "_")
      case Enum.at(parts, 1) do
        nil -> acc
        val ->
          case Integer.parse(val) do
            {int, _} -> [int | acc]
            :error -> acc
          end
      end
    end) |> Enum.sort()

    case Enum.find(bases, &(&1 > current_base)) do
      nil -> :no_more_segments
      next_base -> {:ok, next_base}
    end
  end

  defp load_manifest(shard) do
    shard_dir = Path.join(@base_dir, "#{shard}")
    path = Path.join(shard_dir, "#{shard}.manifest")

    if File.exists?(path) do
      # Read and ensure it's a map
      data = :erlang.binary_to_term(File.read!(path))

      # Normalize: Ensure we have the keys we expect as Atoms
      %{
        active_base: Map.get(data, :active_base) || Map.get(data, "active_base", 1),
        active_ts: Map.get(data, :active_ts) || Map.get(data, "active_ts", System.system_time(:second)),
        msg_count: Map.get(data, :msg_count) || Map.get(data, "msg_count", 0),
        expired: Map.get(data, :expired) || Map.get(data, "expired", %{}),
        exists: true
      }
    else
      %{active_base: 1, active_ts: System.system_time(:second), msg_count: 0, expired: %{}, exists: false}
    end
  end

  defp calculate_current_count(shard, base) do
    u_offsets = user_offsets_tab(shard)
    case :ets.match(u_offsets, {{:"$1", :"$2"}, :"$3"}) do
      [] -> 0
      matches ->
        max_off = Enum.reduce(matches, 0, fn [_, _, off], acc -> max(off, acc) end)
        if max_off >= base, do: max_off - (base - 1), else: 0
    end
  end

  def system_recovery(user) do
    shard = :erlang.phash2(user, @num_shards)
    cache = :"device_bookmarks_cache_#{shard}"

    if :ets.lookup(cache, user) == [] do
      bin_path = Path.join("data/device_bookmarks", "#{shard}.bin")
      bak_path = Path.join("data/device_bookmarks", "#{shard}.bin.bak")

      case try_load_user(shard, bin_path, user) do
        {:ok, data} -> perform_recovery(user, cache, data)
        _error ->
          case try_load_user(shard, bak_path, user) do
            {:ok, data} -> perform_recovery(user, cache, data)
            error -> error
          end
      end
    else
      :already_loaded
    end
  end

  defp try_load_user(shard, path, user) do
    case Queue.FDPoolShard.read_bin(shard, path) do
      {:ok, binary} when binary != <<>> ->
        try do
          all_data = :erlang.binary_to_term(binary)
          case Map.get(all_data, user) do
            nil -> {:error, :not_found}
            data -> {:ok, data}
          end
        rescue
          _ -> {:error, :corrupted}
        end
      _ -> {:error, :no_file}
    end
  end

  defp perform_recovery(user, cache, data) do
    shard = :erlang.phash2(user, @num_shards)
    u_offsets = user_offsets_tab(shard)

    # 1. Seat the metadata cache
    :ets.insert(cache, {user, data})

    # 2. 🚀 THE CRITICAL SEED
    if anchor = data["__anchor__"] do
      {_seg_key, off} = anchor

      # FIX: This must match the {user, partition_id} used in write/9
      # If your write uses partition 0, change the 1 below to 0.
      # If you use multiple partitions, you should store the ID in the anchor.
      :ets.insert(u_offsets, {{user, 0}, off})
    end
    :ok
  end

  defp drain_buf(buf, state, _continuation \\ nil) do
    u_offsets = user_offsets_tab(state.shard)

    # 1. Get current boundaries
    last_ptr = :ets.lookup_element(u_offsets, {:last_shard_offset, state.shard}, 2)
    current_head = :ets.lookup_element(u_offsets, {:shard_offset, state.shard}, 2)

    start_idx = last_ptr + 1
    end_idx = min(start_idx + @stable_limit - 1, current_head)

    if start_idx > current_head do
      # Only log if you want to see the "idle" shards finishing
      # Logger.debug("Shard #{state.shard} idle.")
      finish_flush(state)
    else
      # 2. Fetch the nested tuple
      {items, last_processed_idx} =
        Enum.reduce_while(start_idx..end_idx, {[], last_ptr}, fn i, {acc, _prev} ->
          case :ets.lookup(buf, i) do
            [{^i, {shard, offset, record}}] ->
              :ets.delete(buf, i)
              old_shape = {{shard, offset, i}, record}
              {:cont, {[old_shape | acc], i}}

            [] ->
              {:halt, {acc, i - 1}}
          end
        end)

      if items == [] do
        finish_flush(state)
      else
        :ets.insert(u_offsets, {{:last_shard_offset, state.shard}, last_processed_idx})

        # Process the batch
        new_state = process_batch(state, Enum.reverse(items))

        # 3. Check for recursion
        if :ets.first(buf) != :"$end_of_table" do
          # ADD THIS LOG
          Logger.info("Shard #{state.shard} RECURSING: More data found in buffer. Ptr: #{last_processed_idx}")
          drain_buf(buf, new_state)
        else
          Logger.info("Shard #{state.shard} DRAIN FINISHED: Buffer empty at Ptr: #{last_processed_idx}")
          :file.datasync(state.log_fd)
          :file.datasync(state.idx_fd)
          finish_flush(new_state)
        end
      end
    end
  end

  defp finish_flush(state) do
    :ets.insert(@flush_state, {state.shard, :idle})
    Logger.debug("Shard #{state.shard} marked idle. Next flush scheduled.")
    schedule_flush()
    state
  end

  @impl true
  def handle_info(:flush, state) do
    shard = state.shard
    buf = log_buffer(shard)

    # Check busy status only
    is_busy = :ets.lookup(@flush_state, shard) == [{shard, :busy}]

    if is_busy do
      Logger.debug("Shard #{shard} flush skipped: already busy.")
      {:noreply, state}
    else
      Logger.info("Shard #{shard} flush starting.")
      :ets.insert(@flush_state, {shard, :busy})

      # Start the drain process
      new_state = drain_buf(buf, state)
      {:noreply, new_state}
    end
  end

  # HELPERS
  defp user_offsets_tab(s), do: :"#{@user_offsets_prefix}#{s}"
  defp checkpoints_tab(s), do: :"#{@checkpoints_prefix}#{s}"
  defp user_segment_counts_tab(s), do: :"#{@user_segment_counts_prefix}#{s}"
  defp log_buffer(s), do: :"#{@log_buffer_prefix}#{s}"
  defp idx_cache(s), do: :"#{@idx_cache_prefix}#{s}"
  defp worker_name(s), do: :"bimip_shard_#{s}"

  defp schedule_flush do
    interval = @flush_interval + :rand.uniform(10_000)
    Process.send_after(self(), :flush, interval)
  end

  @impl true
  def terminate(_reason, state) do
    perform_flush(state)
    snapshot_bin(state)
    :file.close(state.log_fd)
    :file.close(state.idx_fd)
    :ok
  end
end
