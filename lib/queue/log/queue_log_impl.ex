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
  @max_messages_per_seg 1_000_000
  @user_stride 1_000
  @max_buffer_per_shard 10_000_000

  @checkpoints_prefix :bimip_segment_checkpoints_
  @user_offsets_prefix :bimip_user_offsets_
  @user_segment_counts_prefix :bimip_user_segment_counts_
  @idx_cache_prefix :"bimip_idx_"
  @log_buffer_prefix :"bimip_buf_"
  @stable_limit 50_000
  @flush_state :flush_state
  @retention_seconds 60 * 60 * 24 * 1

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
        # 1. Initialize Shard Globals
        :ets.insert(user_offsets_tab(s), {{:shard_offset, s}, 0})
        :ets.insert(user_offsets_tab(s), {{:last_shard_offset, s}, 0})
      end

      if :ets.info(checkpoints_tab(s)) == :undefined, do: :ets.new(checkpoints_tab(s), [:named_table, :public, :set, {:read_concurrency, true}])
      if :ets.info(user_segment_counts_tab(s)) == :undefined, do: :ets.new(user_segment_counts_tab(s), [:named_table, :public, :set, {:write_concurrency, true}])
    end
    :ok
  end

  def write(message_builder) do
    # partition_id, sender_uid, recipient_uid, device_id, type, payload_ctx, payload, message_id, ts
    # shard = :erlang.phash2(recipient_uid, @num_shards)
    # buf = log_buffer(shard)

    # if :ets.info(buf, :size) > @max_buffer_per_shard do
    #   {:error, :backpressure}
    # else
    #   # 🚀 FIX: Get both offsets atomically from the ShardServer
    #   {offset, shard_offset} = Queue.ShardServer.get_next_offsets(shard, recipient_uid)
    #   data = Queue.Persist.build(%{payload: payload}, offset , shard_offset, recipient_uid, type, payload_ctx)

    #   record = %{
    #     u: recipient_uid,
    #     s: sender_uid,
    #     p: partition_id,
    #     off: offset,
    #     mid: message_id,
    #     msg_count: shard_offset, # This is now perfectly synced with 'off'
    #     writer_device: to_string(device_id),
    #     bin: :erlang.term_to_binary(data, [:compressed]),
    #     ts: ts
    #   }

    #   :ets.insert(buf, {shard_offset, {shard, offset, record}})
    #   {:ok, offset}
    # end
    {:ok, 10}
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
    # 🚀 TRAP EXIT: Essential for allowing terminate/2 to run during shutdown.
    Process.flag(:trap_exit, true)

    shard_dir = Path.join(@base_dir, "#{shard}")
    File.mkdir_p!(shard_dir)
    File.mkdir_p!("data/device_bookmarks")

    manifest = load_manifest(shard)
    base = manifest.active_base
    ts = manifest.active_ts
    global_offset = manifest.msg_count

    u_offsets = user_offsets_tab(shard)

    # Restore Shard Globals
    :ets.insert(u_offsets, {{:shard_offset, shard}, global_offset})
    :ets.insert(u_offsets, {{:last_shard_offset, shard}, global_offset})

    # Derive relative segment count
    recovered_msg_count = max(0, global_offset - (base - 1))

    log_path = Path.join(shard_dir, "#{shard}_#{base}_#{ts}.log")
    idx_path = Path.join(shard_dir, "#{shard}_#{base}_#{ts}.idx")

    # Open File Handles
    {:ok, log_fd} = :file.open(log_path, [:append, :raw, :binary, :read, :delayed_write])
    {:ok, idx_fd} = :file.open(idx_path, [:append, :raw, :binary, :read, :write])

    # 🚀 INTEGRITY CHECK: Compare Manifest vs Actual Disk Size
    # We ask the OS where the file ends currently.
    {:ok, actual_disk_size} = :file.position(log_fd, :eof)

    # Use the manifest position, but don't exceed the actual physical file.
    # This prevents "pointing to ghost data" if the file was truncated.
    recovered_pos = if manifest.last_pos <= actual_disk_size do
      manifest.last_pos
    else
      Logger.warning("⚠️ Shard #{shard} Manifest mismatch! Manifest: #{manifest.last_pos}, Disk: #{actual_disk_size}. Reverting to Disk size.")
      actual_disk_size
    end

    # Seed ETS manifest snapshot
    :ets.insert(u_offsets, {:manifest_snapshot, manifest})
    if not manifest.exists, do: write_manifest(shard, manifest)

    state = %{
      shard: shard,
      shard_dir: shard_dir,
      log_fd: log_fd,
      idx_fd: idx_fd,
      current_size: recovered_pos,   # 🚀 Validated physical position
      msg_count: recovered_msg_count,
      active_base: base,
      active_ts: ts,
      manifest: manifest
    }

    schedule_flush()

    bin_path = Path.join("data/device_bookmarks", "#{shard}.bin")
    if !File.exists?(bin_path), do: snapshot_bin(state)

    {:ok, state}
  end

  defp recover_user_stride_counts_to_ets(shard, active_base) do
    u_counts = user_segment_counts_tab(shard)
    u_offsets = user_offsets_tab(shard)
    bin_path = Path.join("data/device_bookmarks", "#{shard}.bin")

    # 🚀 BOOT-TIME READ: Direct file access to avoid GenServer timeouts/crashes
    user_data_map = if File.exists?(bin_path) do
      case File.read(bin_path) do
        {:ok, <<>>} -> %{}
        {:ok, binary} ->
          try do
            :erlang.binary_to_term(binary)
          rescue
            _ -> %{}
          end
        {:error, _} -> %{}
      end
    else
      %{}
    end

    Enum.each(user_data_map, fn {user, data} ->
      if anchor = Map.get(data, "__anchor__") do
        {_seg_key, last_off} = anchor

        # 1. Restore the User Offset (This makes it start at 21)
        :ets.insert(u_offsets, {{user, 1}, last_off})

        # 2. Restore the Stride Count
        count_in_seg = max(0, last_off - (active_base - 1))
        :ets.insert(u_counts, {user, count_in_seg})

        # 3. Seed the Bookmark Cache so the next write has a base to work from
        cache_tab = :"device_bookmarks_cache_#{shard}"
        if :ets.info(cache_tab) != :undefined do
          :ets.insert(cache_tab, {user, data})
        end
      end
    end)
  end

  def handle_call({:fetch, user, p, device_id, batch_size}, _from, state) do
    cache = :"device_bookmarks_cache_#{state.shard}"
    today = Date.utc_today() |> Date.to_iso8601()

    # --- STEP 1: LOAD & RECONCILE ---
    user_data = case :ets.lookup(cache, user) do
      [{^user, %{"exp" => %{"last_check_date" => ^today}} = data}] -> data
      [{^user, data}] ->
        reconciled = reconcile_user_data(data, state.manifest)
        :ets.insert(cache, {user, reconciled})
        reconciled
      [] ->
        case system_recovery(user, p) do
          :ok ->
            [{^user, data}] = :ets.lookup(cache, user)
            reconciled = reconcile_user_data(data, state.manifest)
            :ets.insert(cache, {user, reconciled})
            reconciled
          _ -> %{}
        end
    end

    # --- STEP 2: IDENTIFY STARTING POINT ---
    {seg_id, last_off} = case Map.get(user_data, device_id) do
      {s, o} -> {s, o}
      nil -> {find_oldest_valid_segment(user_data, state.manifest), 0}
    end

    # --- STEP 3: RESOLVE PHYSICAL JUMP (Disk only) ---
    target_base = case String.split(seg_id, "_") do
      [base_str | _] -> String.to_integer(base_str)
      _ -> state.active_base
    end

    gate_off = if last_off > 0, do: last_off - rem(last_off - 1, @user_stride), else: 0

    {actual_seg_base, actual_phys} = case :ets.lookup(idx_cache(state.shard), {user, p, gate_off}) do
      [{_, {^target_base, pos}}] -> {target_base, pos}
      _ -> {target_base, 0}
    end

    # --- STEP 4: FETCH FROM DISK ---
    {:ok, disk_results} = stream_messages(state, user, p, actual_seg_base, actual_phys, batch_size, [], device_id)

    # --- STEP 5: FETCH FROM RAM BUFFER (Zero-Delay) ---
    # 🚀 This is where we solve the delay. We pull from the buffer before it hits disk.
    buffer_tab = log_buffer(state.shard)
    raw_buffer = :ets.select(buffer_tab, [
      {
        {:"$1", {state.shard, :"$2", %{u: user, p: p, bin: :"$3", off: :"$4", writer_device: :"$5"}}},
        [
          {:>, :"$4", last_off},      # 🎯 Filter: Only newer messages
          {:"/=", :"$5", device_id}  # 🎯 Filter: Ignore messages from this device
        ],
        [:"$3"] # Return the binary for decoding
      }
    ])

    unflushed_results = Enum.map(raw_buffer, fn bin ->
      # Decode into the same structure stream_messages returns
      :erlang.binary_to_term(bin, [:safe])
    end)

    # --- STEP 6: MERGE & DEDUP ---
    # Since a flush might be happening, a message could be in BOTH disk and RAM.
    # uniq_by removes the duplicate during the 'handover' window.
    combined = (disk_results ++ unflushed_results)
               |> Enum.uniq_by(fn msg -> msg.offset end)
               |> Enum.filter(fn msg -> msg.offset > last_off end) # Safety filter
               |> Enum.sort_by(fn msg -> msg.offset end)
               |> Enum.take(batch_size)

    {:reply, {:ok, combined}, state}
  end

  defp find_oldest_valid_segment(user_data, manifest) do
    active_seg_key = "#{manifest.active_base}_#{manifest.active_ts}"
    positions = Map.get(user_data, "positions", %{})

    case Map.keys(positions) do
      [] -> active_seg_key
      keys ->
        # 🚀 FIX: Sort by the integer value of the base offset
        keys
        |> Enum.sort_by(fn key ->
          [base_str | _] = String.split(key, "_")
          String.to_integer(base_str)
        end, :asc)
        |> List.first()
    end
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
    # 1. Split items based on how much space is left in the current segment
    space_left = @max_messages_per_seg - state.msg_count
    {to_write, leftovers} = Enum.split(items, space_left)
    u_counts_tab = user_segment_counts_tab(state.shard)

    if to_write != [] do
      # --- STEP A: PRE-BATCH FETCH ---
      # Get unique users in this specific batch to minimize ETS lookups
      unique_users = to_write |> Enum.map(fn {_, rec} -> rec.u end) |> Enum.uniq()

      # Load starting counts into a local map for the loop
      base_counts = Enum.reduce(unique_users, %{}, fn u, acc ->
        current = case :ets.lookup(u_counts_tab, u) do
          [{^u, val}] -> val
          [] -> 0
        end
        Map.put(acc, u, current)
      end)

      # --- STEP B: THE ACCUMULATOR LOOP ---
      {bin_io, idx_io, final_count, final_phys, updates, latest_map, final_local_counts} =
        Enum.reduce(to_write, {[], [], state.msg_count, state.current_size, [], %{}, base_counts},
          fn {{_s, _off, _seq}, rec}, {b_acc, i_acc, curr_idx, curr_phys, upd, l_map, current_counts_map} ->

            # Increment local count for this user
            new_u_count = Map.get(current_counts_map, rec.u) + 1
            updated_counts_map = Map.put(current_counts_map, rec.u, new_u_count)

            # Encode packet for log file
            {bin_packet, p_size} = encode_packet(rec, rec.off, state)

            # STRIDE LOGIC: Check boundary (1, 1001, 2001...)
            {new_i_acc, new_upd} =
              if rem(new_u_count - 1, @user_stride) == 0 do
                u_bin = to_string(rec.u)
                idx_entry = <<byte_size(u_bin)::16, u_bin::binary, rec.p::32, rec.off::64, state.active_base::64, curr_phys::64>>

                # Update index cache for immediate reads
                :ets.insert(idx_cache(state.shard), {{rec.u, rec.p, rec.off}, {state.active_base, curr_phys}})

                {[i_acc | idx_entry], [{rec.u, rec.off} | upd]}
              else
                {i_acc, upd}
              end

              new_l_map = Map.put(l_map, rec.u, rec.off)

            # Accumulate and pass the updated_counts_map to the next iteration
            {[b_acc | bin_packet], new_i_acc, curr_idx + 1, curr_phys + p_size, new_upd, Map.put(l_map, rec.u, rec.off), updated_counts_map}
          end)

      # --- STEP C: BULK COMMITS ---
      # 1. Commit the final user counts to ETS in one pass
      Enum.each(final_local_counts, fn {u, final_val} ->
        :ets.insert(u_counts_tab, {u, final_val})
      end)

      # 2. Disk I/O: One big write call for the log and index
      :file.write(state.log_fd, bin_io)
      :file.write(state.idx_fd, idx_io)

      Queue.Replicator.push_flush(state.shard, state.active_base, bin_io, idx_io)

      # 3. Update Manifest and Shard Globals
      {_last_tag, last_record} = List.last(to_write)
      u_offsets = user_offsets_tab(state.shard)
      manifest = get_manifest_cached(state.shard)

      updated_manifest = %{manifest | msg_count: last_record.msg_count, last_pos: final_phys }
      write_manifest(state.shard, updated_manifest)
      :ets.insert(u_offsets, {:manifest_snapshot, updated_manifest})

      cache = :"device_bookmarks_cache_#{state.shard}"
      file_id = "#{state.active_base}_#{state.active_ts}"

      Enum.each(latest_map, fn {u, max_off} ->
        # We fetch the existing record for THIS specific user only
        case :ets.lookup(cache, u) do
          [{^u, map}] ->
            # We update ONLY this user's anchor.
            # User A's anchor remains 'seg1' because we don't touch their record.
            updated_map = Map.put(map, "__anchor__", {file_id, max_off})
            :ets.insert(cache, {u, updated_map})

          [] ->
            # New user record
            :ets.insert(cache, {u, %{"__anchor__" => {file_id, max_off}}})
        end
      end)

      Enum.each(updates, fn {u, off} ->
        Queue.DeviceBookmark.mark_position(u, "#{state.active_base}_#{state.active_ts}", off)
      end)

      new_state = %{state | msg_count: final_count, current_size: final_phys}

      # --- STEP D: ROTATION CHECK ---
      if new_state.msg_count >= @max_messages_per_seg do
        snapshot_bin(new_state)
        rotated_state = rotate_segment(new_state)
        # Recurse for leftovers in the new segment
        process_batch(rotated_state, leftovers, depth + 1)
      else
        # If there are leftovers but no rotation (rare), process them
        process_batch(new_state, leftovers, depth + 1)
      end
    else
      state
    end
  end

  defp reconcile_user_data(user_data, manifest) do
    today = Date.utc_today() |> Date.to_iso8601()
    last_check = get_in(user_data, ["exp", "last_check_date"]) || "1970-01-01"

    if last_check < today do
      expired_map = manifest.expired

      # 1. Filter Positions: Removes segments that no longer exist on disk
      new_positions =
        (user_data["positions"] || %{})
        |> Enum.reject(fn {seg, _} -> Map.has_key?(expired_map, seg) end)
        |> Map.new()

      # 2. Filter Device Bookmarks: Purge "Ghost Pointers"
      cleaned_map = Enum.reduce(user_data, %{}, fn
        # Match a device entry: key is device_id, value is {seg, off}
        {k, {seg, off}}, acc when is_binary(k) and k not in ["exp", "positions", "__anchor__"] ->
          if Map.has_key?(expired_map, seg) do
            acc # Drop it: the file this device was reading is gone
          else
            Map.put(acc, k, {seg, off}) # Keep it: file is still valid
          end

        # Keep metadata keys as they are
        {k, v}, acc -> Map.put(acc, k, v)
      end)

      cleaned_map
      |> Map.put("positions", new_positions)
      |> Map.put("exp", %{"last_check_date" => today, "status" => :attended})
    else
      user_data
    end
  end

  defp snapshot_bin(state) do
    cache = :"device_bookmarks_cache_#{state.shard}"
    bin_path = Path.join("data/device_bookmarks", "#{state.shard}.bin")

    hot_map = if :ets.info(cache) != :undefined do
      :ets.tab2list(cache) |> Map.new()
    else
      %{}
    end

    bin = :erlang.term_to_binary(hot_map, [:compressed])
    Queue.FDPoolShard.atomic_snapshot(state.shard, bin_path, bin)
    Queue.Replicator.push_snapshot(state.shard, bin)
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

    # 🚀 FIX: Sync current log and index to physical disk BEFORE closing.
    # This ensures no data is trapped in the OS buffer if a crash occurs now.
    :file.datasync(state.log_fd)
    :file.datasync(state.idx_fd)

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
      last_pos: 0,
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
    Queue.Replicator.push_manifest(shard, manifest_data)
  end

defp read_from_disk(state, base, pos) do
    # 🚀 PATH OPTIMIZATION:
    # Construct path directly to avoid expensive directory scanning (wildcards).
    ts = if base == state.active_base do
      state.active_ts
    else
      # Look for the timestamp in the manifest.expired map.
      # Note: Ensure your manifest keys are strings if they come from JSON/External sources.
      Map.get(state.manifest.expired, "#{base}")
    end

    path = if ts do
      Path.join(state.shard_dir, "#{state.shard}_#{base}_#{ts}.log")
    else
      # Emergency Fallback: If for some reason the TS isn't in the manifest,
      # we do one wildcard search to find the file.
      case Path.wildcard(Path.join(state.shard_dir, "#{state.shard}_#{base}_*.log")) do
        [p | _] -> p
        [] -> nil
      end
    end

    if path do
      # 1. Read the fixed-size header
      case Queue.FDPoolShard.pread(state.shard, path, pos, @header_size) do
        {:ok, <<0xEE, size::32, stored_crc::32, ulen::16, dlen::16, _ts::64>>} ->

          # 2. Read the variable-length body
          # (u_bin + d_bin + p(32) + off(64) + body) = ulen + dlen + 12 + size
          total_body_size = ulen + dlen + 12 + size

          case Queue.FDPoolShard.pread(state.shard, path, pos + @header_size, total_body_size) do
            {:ok, <<u::binary-size(ulen), d::binary-size(dlen), p::32, off::64, body::binary-size(size)>>} ->

              # 🚀 CRC Validation
              if :erlang.crc32(body) == stored_crc do
                try do
                  decoded_data = :erlang.binary_to_term(body, [:safe])
                  new_pos = pos + @header_size + total_body_size
                  {:ok, %{u: u, writer_device: d, p: p, off: off, data: decoded_data}, new_pos}
                rescue
                  _ -> {:error, :term_decode_failed}
                end
              else
                Logger.error("💾 CRC Mismatch at shard #{state.shard}, pos #{pos}. Data corrupted.")
                {:error, :corrupted_record}
              end

            _ -> {:error, :body_read_failed}
          end
        :eof -> {:error, :eof}
        _ -> {:error, :header_read_failed}
      end
    else
      {:error, :file_not_found}
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

  def load_manifest(shard) do
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
        last_pos: Map.get(data, :last_pos) || 0,
        expired: Map.get(data, :expired) || Map.get(data, "expired", %{}),
        exists: true
      }
    else
      %{active_base: 1, active_ts: System.system_time(:second), msg_count: 0, last_pos: 0, expired: %{}, exists: false}
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

  def system_recovery(user, partition_id) do
    shard = :erlang.phash2(user, @num_shards)
    cache = :"device_bookmarks_cache_#{shard}"

    if :ets.lookup(cache, user) == [] do
      bin_path = Path.join("data/device_bookmarks", "#{shard}.bin")
      bak_path = Path.join("data/device_bookmarks", "#{shard}.bin.bak")

      case try_load_user(shard, bin_path, user) do
        {:ok, data} -> perform_recovery(user, partition_id, cache, data)
        _error ->
          case try_load_user(shard, bak_path, user) do
            {:ok, data} -> perform_recovery(user, partition_id, cache, data)
            error -> error
          end
      end
    else
      :already_loaded
    end
  end

  defp perform_recovery(user, partition_id, cache, data) do

    shard = :erlang.phash2(user, @num_shards)
    u_offsets = user_offsets_tab(shard)
    u_counts = user_segment_counts_tab(shard)
    idx_tab = idx_cache(shard)

    :ets.insert(cache, {user, data})

    if positions = Map.get(data, "positions") do
      Enum.each(positions, fn {seg_key, user_off} ->
        [base_str | _] = String.split(seg_key, "_")
        base = String.to_integer(base_str)
        # Put the sparse index back so 'fetch_batch' is fast
        :ets.insert(idx_tab, {{user, partition_id, user_off}, {base, 0}})
      end)
    end

    if anchor = data["__anchor__"] do
      {_seg_key, off} = anchor
      key = {user, partition_id}

      # This part is CRITICAL. It tells ETS: "This user is already at 11"
      # If this fails, the next update_counter starts at 1.
      :ets.insert(u_offsets, {key, off})

      # Recalculate stride
      manifest = get_manifest_cached(shard)
      count_in_seg = max(0, off - (manifest.active_base - 1))
      :ets.insert(user_segment_counts_tab(shard), {user, count_in_seg})
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

        # 1. Write the batch to the .log file
        new_state = process_batch(state, Enum.reverse(items), 0)

        # 🚀 THE FIX: Snapshot IMMEDIATELY after the batch is processed.
        # This guarantees the .bin file reflects what was just written to the .log.
        snapshot_bin(new_state)

        # 3. Check for recursion
        if :ets.first(buf) != :"$end_of_table" do
          Logger.info("Shard #{state.shard} RECURSING: More data found in buffer. Ptr: #{last_processed_idx}")
          drain_buf(buf, new_state)
        else
          Logger.info("Shard #{state.shard} DRAIN FINISHED: Buffer empty at Ptr: #{last_processed_idx}")
          # No longer need snapshot_bin here because it happened above!
          :file.datasync(state.log_fd)
          :file.datasync(state.idx_fd)
          finish_flush(new_state)
        end
      end
    end
  end

  defp get_manifest_cached(shard) do
    u_offsets = user_offsets_tab(shard)

    # Check ETS first for the "live" manifest snapshot
    case :ets.lookup(u_offsets, :manifest_snapshot) do
      [{:manifest_snapshot, manifest}] ->
        manifest
      [] ->
        # Fallback to disk if the process just started or ETS was cleared
        load_manifest(shard)
    end
  end

  @impl true
  def handle_info(:flush, state) do
    shard = state.shard
    buf = log_buffer(shard)

    is_busy = case :ets.lookup(@flush_state, shard) do
      [{^shard, {:busy, pid}}] -> Process.alive?(pid)
      _ -> false
    end

    if is_busy do
      {:noreply, state}
    else
      :ets.insert(@flush_state, {shard, {:busy, self()}})

      # 🚀 We remove the 'after' and handle the lock release
      # based on whether the result was a success or a crash.
      try do
        new_state = drain_buf(buf, state)

        # SUCCESS PATH:
        # drain_buf already calls finish_flush(new_state) internally
        # which releases the lock and returns the NEW state.
        {:noreply, new_state}
      rescue
        e ->
          # FAILURE PATH:
          Logger.error("❌ Shard #{shard} flush CRASHED: #{inspect(e)}")

          # Manually release the lock so the shard isn't stuck forever
          :ets.insert(@flush_state, {shard, :idle})
          schedule_flush()

          # Return the original state so we can try again later
          {:noreply, state}
      end
    end
  end

  defp finish_flush(state) do
    # Clear the lock and schedule next check
    :ets.insert(@flush_state, {state.shard, :idle})
    Logger.debug("Shard #{state.shard} marked idle. Next flush scheduled.")
    schedule_flush()
    state
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
  def handle_cast(:trigger_maintenance, state) do
    shard = state.shard

    # 1. 🚀 PID-Aware Lock Validation
    # Checks if the lock is held by a currently running process
    is_busy = case :ets.lookup(@flush_state, shard) do
      [{^shard, {:busy, pid}}] -> Process.alive?(pid)
      [{^shard, :busy}] -> true # Legacy support
      _ -> false
    end

    if is_busy do
      Logger.warning("Shard #{shard} maintenance skipped: BUSY (Lock held by active process)")
      {:noreply, state}
    else
      # 2. Acquire Lock with current PID
      :ets.insert(@flush_state, {shard, {:busy, self()}})

      try do
        # 3. Get manifest from ETS (The live version)
        manifest = get_manifest_cached(shard)
        now = System.system_time(:second)

        # 4. Filter based on retention
        expired_ids =
          manifest.expired
          |> Enum.filter(fn {_id, ts} -> (now - ts) > @retention_seconds end)
          |> Enum.map(fn {id, _ts} -> id end)

        if expired_ids == [] do
          Logger.info("Shard #{shard} maintenance: Nothing old enough to archive yet.")
          {:noreply, state}
        else
          Logger.info("🧹 Shard #{shard} archiving: #{inspect(expired_ids)}")

          # 5. Perform the move (The heavy lifting)
          new_manifest_map = perform_archival(state, manifest, expired_ids)

          # 6. Save results back to ETS and Disk
          u_offsets = user_offsets_tab(shard)
          :ets.insert(u_offsets, {:manifest_snapshot, new_manifest_map})
          write_manifest(shard, new_manifest_map)

          {:noreply, %{state | manifest: new_manifest_map}}
        end
      rescue
        e ->
          Logger.error("❌ Shard #{shard} maintenance CRASHED: #{inspect(e)}")
          {:noreply, state}
      after
        # 7. 🛡️ Safety Release: Always set back to idle, no matter what happened
        :ets.insert(@flush_state, {shard, :idle})
      end
    end
  end

  @impl true
@impl true
def handle_cast({:ack, user, device_id, ack_offset}, state) do
  cache = :"device_bookmarks_cache_#{state.shard}"

  case :ets.lookup(cache, user) do
    [{^user, user_data}] ->
      # 1. Resolve Segment
      positions = Map.get(user_data, "positions", %{})
      resolved_seg = find_segment_for_offset(positions, ack_offset, state.active_base)

      # 2. Update/Create the device entry
      updated_user_data = Map.put(user_data, device_id, {resolved_seg, ack_offset})

      # 3. Commit
      :ets.insert(cache, {user, updated_user_data})
      Logger.debug("Ack processed: #{user} on #{device_id} -> Seg #{resolved_seg}")

    [] ->
      # This is likely a truly new user.
      # We create a minimal record so the Ack isn't lost.
      file_id = "#{state.active_base}_#{state.active_ts}"
      new_user_data = %{
        device_id => {file_id, ack_offset},
        "positions" => %{},
        "__anchor__" => {file_id, ack_offset} # 🚀 CRITICAL for Step 5 Recovery
      }
      :ets.insert(cache, {user, new_user_data})
      Logger.info("Created new bookmark record for user: #{user} via Ack")
  end

  {:noreply, state}
end

  # Helper to find the "Landing Zone" for an offset
  defp find_segment_for_offset(positions, ack_offset, active_base) do
    if positions == %{} do
      # Fallback if no history exists
      "#{active_base}"
    else
      # Find the highest base_offset that is <= our ack_offset
      best_seg =
        positions
        |> Enum.filter(fn {_seg_key, start_off} -> start_off <= ack_offset end)
        |> Enum.max_by(fn {_seg_key, start_off} -> start_off end, fn -> nil end)

      case best_seg do
        {seg_id, _start_off} -> seg_id
        nil -> "#{active_base}"
      end
    end
  end

  def acknowledge(user, device_id, last_seen_offset) do
    shard = :erlang.phash2(user, @num_shards)
    GenServer.cast(worker_name(shard), {:ack, user, to_string(device_id), last_seen_offset})
  end

  defp perform_archival(state, manifest, expired_ids) do
    # 1. Setup Archive Path (e.g., data/archive/37)
    archive_dir = Path.join("data/archive", "#{state.shard}")

    case File.mkdir_p(archive_dir) do
      :ok -> :ok
      {:error, reason} -> Logger.error("Could not create archive dir: #{inspect(reason)}")
    end

    Enum.each(expired_ids, fn seg_id ->
      Logger.info("🧹 Processing archival for Shard #{state.shard}, Segment #{seg_id}")

      # A. Close the File Descriptors in the FDPool
      # This prevents 'stale file handle' errors during the move
      Queue.FDPoolShard.close_fd(state.shard, seg_id)

      # B. Build the Search Pattern
      # Matches: data/bimip/37/37_1_1769445066.*
      search_pattern = Path.join(state.shard_dir, "#{state.shard}_#{seg_id}.*")

      case Path.wildcard(search_pattern) do
        [] ->
          Logger.warning("⚠️ Shard #{state.shard}: No files found matching pattern: #{search_pattern}")

        files ->
          Enum.each(files, fn old_path ->
            filename = Path.basename(old_path)
            new_path = Path.join(archive_dir, filename)

            # C. Physically move the file from Primary to Archive
            case File.rename(old_path, new_path) do
              :ok ->
                Logger.info("✅ Successfully archived: #{filename}")
              {:error, reason} ->
                Logger.error("❌ Failed to move #{filename} to #{new_path}: #{inspect(reason)}")
            end
          end)
      end

      # D. Cleanup the Index Cache (ETS)
      # We remove any sparse index pointers for this segment so the Reader
      # doesn't try to read archived files from the primary folder.
      [base_str | _] = String.split(seg_id, "_")
      base_id = String.to_integer(base_str)

      # This matches any key {user, partition, offset} where the value is {base_id, _}
      :ets.match_delete(idx_cache(state.shard), {{:"$1", :"$2", :"$3"}, {base_id, :"$4"}})
    end)

    # 3. Update the Manifest
    # Remove the archived IDs from the 'expired' map and return the new map
    %{manifest | expired: Map.drop(manifest.expired, expired_ids)}
  end

  defp prune_stale_bookmarks(user, shard, manifest) do
    cache = :"device_bookmarks_cache_#{shard}"

    case :ets.lookup(cache, user) do
      [{^user, data}] ->
        # Get the list of segments that actually exist (active + expired)
        valid_segments = Map.keys(manifest.expired) ++ ["#{manifest.active_base}_#{manifest.active_ts}"]

        # Filter the positions map: keep only what exists on disk
        current_positions = Map.get(data, "positions", %{})
        new_positions = Map.filter(current_positions, fn {seg_key, _off} ->
          seg_key in valid_segments
        end)

        # If we removed something, update ETS (The "Fix on Read")
        if map_size(current_positions) != map_size(new_positions) do
          updated_data = Map.put(data, "positions", new_positions)
          :ets.insert(cache, {user, updated_data})
          Logger.debug("Cleaned up archived bookmarks for user #{user}")
        end
      _ -> :ok
    end
  end

  @impl true
  def terminate(reason, state) do
    Logger.info("🛑 [Shard #{state.shard}] Shutdown initiated (Reason: #{inspect(reason)})")

    # 1. Final Flush: Drains any messages in the ETS buffer to the .log file
    # This respects the 'busy/idle' state of the shard before closing.
    try do
      perform_flush(state)
      Logger.info("✅ [Shard #{state.shard}] Final buffer flush successful.")
    rescue
      e -> Logger.error("❌ [Shard #{state.shard}] Final flush failed: #{inspect(e)}")
    end

    # 2. Final Snapshot: Save user bookmarks to the .bin file
    try do
      snapshot_bin(state)
      Logger.info("✅ [Shard #{state.shard}] Final bookmark snapshot saved.")
    rescue
      e -> Logger.error("❌ [Shard #{state.shard}] Bookmark snapshot failed: #{inspect(e)}")
    end

    # 3. Handle Closure: Safety close to ensure OS releases locks
    :file.close(state.log_fd)
    :file.close(state.idx_fd)

    Logger.info("👋 [Shard #{state.shard}] Safety shutdown complete.")
    :ok
  end
end
