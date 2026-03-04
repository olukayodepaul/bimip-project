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

  @partition 1

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
        :ets.insert(user_offsets_tab(s), {{:shard_offset, s}, 0})
        :ets.insert(user_offsets_tab(s), {{:last_shard_offset, s}, 0})
      end

      if :ets.info(checkpoints_tab(s)) == :undefined, do: :ets.new(checkpoints_tab(s), [:named_table, :public, :set, {:read_concurrency, true}])
      if :ets.info(user_segment_counts_tab(s)) == :undefined, do: :ets.new(user_segment_counts_tab(s), [:named_table, :public, :set, {:write_concurrency, true}])
    end
    :ok
  end

  def write(%{
    delim: delim,
    uuid: uupid,
    ts: ts,
    message_builder:  %Bimip.Message{} = mbuilder }) do

    {owners, owner_uupid} = if delim == :sender do
      {mbuilder.from.eid, uupid}
    else
      {mbuilder.to.eid, -1}
    end

    shard = :erlang.phash2(owners, @num_shards)
    buf = log_buffer(shard)

    if :ets.info(buf, :size) > @max_buffer_per_shard do
      {:error, :backpressure}
    else
      {offset, shard_offset} = Queue.ShardServer.get_next_offsets(shard, owners)
      data = Queue.Persist.build(mbuilder, offset)

      record = %{
        u: owners,
        s: owners,
        p:  @partition,
        off: offset,
        mid: mbuilder.id,
        msg_count: shard_offset,
        writer_device: to_string(owner_uupid),
        bin: :erlang.term_to_binary(data, [:compressed]),
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
    Process.flag(:trap_exit, true)

    shard_dir = Path.join(@base_dir, "#{shard}")
    File.mkdir_p!(shard_dir)
    File.mkdir_p!("data/device_bookmarks")

    manifest = load_manifest(shard)
    base = manifest.active_base
    ts = manifest.active_ts
    global_offset = manifest.msg_count

    u_offsets = user_offsets_tab(shard)

    :ets.insert(u_offsets, {{:shard_offset, shard}, global_offset})
    :ets.insert(u_offsets, {{:last_shard_offset, shard}, global_offset})

    recovered_msg_count = max(0, global_offset - (base - 1))

    log_path = Path.join(shard_dir, "#{shard}_#{base}_#{ts}.log")
    idx_path = Path.join(shard_dir, "#{shard}_#{base}_#{ts}.idx")

    {:ok, log_fd} = :file.open(log_path, [:append, :raw, :binary, :read, :delayed_write])
    {:ok, idx_fd} = :file.open(idx_path, [:append, :raw, :binary, :read, :write])

    {:ok, actual_disk_size} = :file.position(log_fd, :eof)

    recovered_pos = if manifest.last_pos <= actual_disk_size do
      manifest.last_pos
    else
      Logger.warning("⚠️ Shard #{shard} Manifest mismatch! Manifest: #{manifest.last_pos}, Disk: #{actual_disk_size}. Reverting to Disk size.")
      actual_disk_size
    end

    :ets.insert(u_offsets, {:manifest_snapshot, manifest})
    if not manifest.exists, do: write_manifest(shard, manifest)

    state = %{
      shard: shard,
      shard_dir: shard_dir,
      log_fd: log_fd,
      idx_fd: idx_fd,
      current_size: recovered_pos,
      msg_count: recovered_msg_count,
      active_base: base,
      active_ts: ts,
      manifest: manifest
    }

    # 🚀 REFACTORED: Single Boot Recovery
    full_shard_recovery(shard, manifest)

    schedule_flush()

    bin_path = Path.join("data/device_bookmarks", "#{shard}.bin")
    if !File.exists?(bin_path), do: snapshot_bin(state)

    {:ok, state}
  end

  # --- REFACTORED RECOVERY LOGIC ---

  defp full_shard_recovery(shard, manifest) do
    bin_path = Path.join("data/device_bookmarks", "#{shard}.bin")
    bak_path = Path.join("data/device_bookmarks", "#{shard}.bin.bak")
    cache = :"device_bookmarks_cache_#{shard}"

    # Load the shard's user data into memory once
    user_data_map = case File.read(bin_path) do
      {:ok, bin} -> try_decode(bin)
      _ ->
        case File.read(bak_path) do
          {:ok, bin} -> try_decode(bin)
          _ -> %{}
        end
    end

    # Prime all ETS tables from the loaded map
    Enum.each(user_data_map, fn {user, data} ->
      # 1. Apply Rule #3 (Compaction/Expiry) immediately
      reconciled = reconcile_user_data(data, manifest)
      :ets.insert(cache, {user, reconciled})

      # 2. Re-index Stride points and anchors
      prime_indexes(shard, user, reconciled, manifest)
    end)
  end

  defp try_decode(bin), do: (try do :erlang.binary_to_term(bin) rescue _ -> %{} end)

  defp prime_indexes(shard, user, data, manifest) do
    u_offsets = user_offsets_tab(shard)
    u_counts = user_segment_counts_tab(shard)
    idx_tab = idx_cache(shard)

    # Rebuild the Stride Index for Fetch Jumps
    if positions = Map.get(data, "positions") do
      Enum.each(positions, fn {seg_key, pos_val} ->
        [base_str | _] = String.split(seg_key, "_")
        base = String.to_integer(base_str)
        {u_off, p_pos} = case pos_val do {o, p} -> {o, p}; o -> {o, 0} end
        gate = if u_off > 0, do: u_off - rem(u_off - 1, @user_stride), else: 0
        :ets.insert(idx_tab, {{user, @partition, gate}, {base, p_pos}})
      end)
    end

    # Restore current logical offset and segment counts
    if anchor = data["__anchor__"] do
      {_seg, off} = anchor
      :ets.insert(u_offsets, {{user, @partition}, off})
      # Restore count relative to current file base
      :ets.insert(u_counts, {user, max(0, off - (manifest.active_base - 1))})
    end
  end

  # --- CORE IMPLEMENTATION (REVERTED TO YOURS) ---

  defp find_oldest_valid_segment(user_data, manifest) do
    active_seg_key = "#{manifest.active_base}_#{manifest.active_ts}"
    positions = Map.get(user_data, "positions", %{})

    case Map.keys(positions) do
      [] -> active_seg_key
      keys ->
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
    u_counts_tab = user_segment_counts_tab(state.shard)

    if to_write != [] do
      unique_users = to_write |> Enum.map(fn {_, rec} -> rec.u end) |> Enum.uniq()
      base_counts = Enum.reduce(unique_users, %{}, fn u, acc ->
        current = case :ets.lookup(u_counts_tab, u) do
          [{^u, val}] -> val
          [] -> 0
        end
        Map.put(acc, u, current)
      end)

      {bin_io, idx_io, final_count, final_phys, updates, latest_map, final_local_counts} =
        Enum.reduce(to_write, {[], [], state.msg_count, state.current_size, [], %{}, base_counts},
          fn {{_s, _off, _seq}, rec}, {b_acc, i_acc, curr_idx, curr_phys, upd, l_map, current_counts_map} ->
            new_u_count = Map.get(current_counts_map, rec.u) + 1
            updated_counts_map = Map.put(current_counts_map, rec.u, new_u_count)
            {bin_packet, p_size} = encode_packet(rec, rec.off, state)

           {new_i_acc, new_upd} =
            if rem(new_u_count - 1, @user_stride) == 0 do
              u_bin = to_string(rec.u)
              gate = if rec.off > 0, do: rec.off - rem(rec.off - 1, @user_stride), else: 0
              idx_entry = <<byte_size(u_bin)::16, u_bin::binary, rec.p::32, gate::64, state.active_base::64, curr_phys::64>>
              :ets.insert(idx_cache(state.shard), {{rec.u, rec.p, gate}, {state.active_base, curr_phys}})
              {[i_acc | idx_entry], [{rec.u, rec.off, curr_phys} | upd]}
            else
              {i_acc, upd}
            end

            {[b_acc | bin_packet], new_i_acc, curr_idx + 1, curr_phys + p_size, new_upd, Map.put(l_map, rec.u, rec.off), updated_counts_map}
          end)

      Enum.each(final_local_counts, fn {u, final_val} ->
        :ets.insert(u_counts_tab, {u, final_val})
      end)

      :file.write(state.log_fd, bin_io)
      :file.write(state.idx_fd, idx_io)
      Queue.Replicator.push_flush(state.shard, state.active_base, bin_io, idx_io)

      {_last_tag, last_record} = List.last(to_write)
      u_offsets = user_offsets_tab(state.shard)
      manifest = get_manifest_cached(state.shard)

      updated_manifest = %{manifest | msg_count: last_record.msg_count, last_pos: final_phys }
      write_manifest(state.shard, updated_manifest)
      :ets.insert(u_offsets, {:manifest_snapshot, updated_manifest})

      cache = :"device_bookmarks_cache_#{state.shard}"
      file_id = "#{state.active_base}_#{state.active_ts}"

      Enum.each(latest_map, fn {u, max_off} ->
        case :ets.lookup(cache, u) do
          [{^u, map}] ->
            updated_map = Map.put(map, "__anchor__", {file_id, max_off})
            :ets.insert(cache, {u, updated_map})
          [] ->
            :ets.insert(cache, {u, %{"__anchor__" => {file_id, max_off}}})
        end
      end)

      Enum.each(updates, fn {u, off, phys} ->
        Queue.DeviceBookmark.mark_position(u, "#{state.active_base}_#{state.active_ts}", off, phys)
      end)

      new_state = %{state | msg_count: final_count, current_size: final_phys}
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

 defp reconcile_user_data(user_data, manifest) do
  today = Date.utc_today() |> Date.to_iso8601()
  last_check = get_in(user_data, ["exp", "last_check_date"]) || "1970-01-01"

  if last_check < today do
    # 1. Define the "White List" of valid segments
    active_seg = "#{manifest.active_base}_#{manifest.active_ts}"
    expired_map = manifest.expired || %{}

    # A segment is valid ONLY if it's the active one OR listed in the expired map
    is_valid? = fn seg -> seg == active_seg or Map.has_key?(expired_map, seg) end

    # 2. Clean 'positions' - Remove anything not in manifest
    new_positions =
      (user_data["positions"] || %{})
      |> Enum.filter(fn {seg, _} -> is_valid?.(seg) end)
      |> Map.new()

    # 3. Clean 'device settings' (anchors) and other dynamic keys
    cleaned_map = Enum.reduce(user_data, %{}, fn
      # Match any key where the value is {segment, offset}
      {k, {seg, off}}, acc when is_binary(k) and k not in ["exp", "positions", "__anchor__"] ->
        if is_valid?.(seg), do: Map.put(acc, k, {seg, off}), else: acc

      # Match the global anchor specifically
      {"__anchor__", {seg, off}}, acc ->
        if is_valid?.(seg), do: Map.put(acc, "__anchor__", {seg, off}), else: acc

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
    new_base = state.active_base + state.msg_count
    new_ts = System.system_time(:second)

    :file.datasync(state.log_fd)
    :file.datasync(state.idx_fd)

    :file.close(state.log_fd)
    :file.close(state.idx_fd)

    l_path = Path.join(state.shard_dir, "#{state.shard}_#{new_base}_#{new_ts}.log")
    i_path = Path.join(state.shard_dir, "#{state.shard}_#{new_base}_#{new_ts}.idx")

    {:ok, tmp_l} = :file.open(l_path, [:write, :raw, :binary]); :file.datasync(tmp_l); :file.close(tmp_l)
    {:ok, tmp_i} = :file.open(i_path, [:write, :raw, :binary]); :file.datasync(tmp_i); :file.close(tmp_i)

    case :file.open(state.shard_dir, [:read, :raw]) do
      {:ok, dir_fd} -> :file.datasync(dir_fd); :file.close(dir_fd)
      _ -> :ok
    end

    u_offsets = user_offsets_tab(state.shard)
    current_global_offset = :ets.lookup_element(u_offsets, {:shard_offset, state.shard}, 2)
    manifest = get_manifest_cached(state.shard)

    expired_key = "#{state.active_base}_#{state.active_ts}"
    updated_manifest = %{
      active_base: new_base,
      active_ts: new_ts,
      msg_count: current_global_offset,
      last_pos: 0,
      expired: Map.put(manifest.expired, expired_key, new_ts)
    }

    write_manifest(state.shard, updated_manifest)
    :ets.insert(u_offsets, {:manifest_snapshot, updated_manifest})

    {:ok, l} = :file.open(l_path, [:append, :raw, :binary, :read, :delayed_write])
    {:ok, i} = :file.open(i_path, [:append, :raw, :binary, :read, :write])

    :ets.delete_all_objects(user_segment_counts_tab(state.shard))
    %{state | log_fd: l, idx_fd: i, active_base: new_base, active_ts: new_ts, current_size: 0, msg_count: 0}
  end

  defp write_manifest(shard, manifest_data) do
    shard_dir = Path.join(@base_dir, "#{shard}")
    path = Path.join(shard_dir, "#{shard}.manifest")
    tmp_path = path <> ".tmp"
    storage_map = Map.drop(manifest_data, [:exists])
    binary = :erlang.term_to_binary(storage_map)
    {:ok, fd} = :file.open(tmp_path, [:write, :raw, :binary]); :file.write(fd, binary); :file.datasync(fd); :file.close(fd)
    File.rename!(tmp_path, path)
    Queue.Replicator.push_manifest(shard, manifest_data)
  end

  defp read_from_disk(state, base, pos) do
    ts = if base == state.active_base, do: state.active_ts, else: Map.get(state.manifest.expired, "#{base}")
    path = if ts do
      Path.join(state.shard_dir, "#{state.shard}_#{base}_#{ts}.log")
    else
      case Path.wildcard(Path.join(state.shard_dir, "#{state.shard}_#{base}_*.log")) do
        [p | _] -> p
        [] -> nil
      end
    end

    if path do
      case Queue.FDPoolShard.pread(state.shard, path, pos, @header_size) do
        {:ok, <<0xEE, size::32, stored_crc::32, ulen::16, dlen::16, _ts::64>>} ->
          total_body_size = ulen + dlen + 12 + size
          case Queue.FDPoolShard.pread(state.shard, path, pos + @header_size, total_body_size) do
            {:ok, <<u::binary-size(ulen), d::binary-size(dlen), p::32, off::64, body::binary-size(size)>>} ->
              if :erlang.crc32(body) == stored_crc do
                try do
                  {:ok, %{u: u, writer_device: d, p: p, off: off, data: :erlang.binary_to_term(body)}, pos + @header_size + total_body_size}
                rescue _ -> {:error, :term_decode_failed} end
              else {:error, :corrupted_record} end
            _ -> {:error, :body_read_failed}
          end
        :eof -> {:error, :eof}
        _ -> {:error, :header_read_failed}
      end
    else {:error, :file_not_found} end
  end

  def handle_call({:fetch, user, p, device_id, batch_size}, _from, state) do
    cache = :"device_bookmarks_cache_#{state.shard}"
    today = Date.utc_today() |> Date.to_iso8601()

    user_data = case :ets.lookup(cache, user) do
      [{^user, %{"exp" => %{"last_check_date" => ^today}} = data}] -> data
      [{^user, data}] ->
        reconciled = reconcile_user_data(data, state.manifest)
        :ets.insert(cache, {user, reconciled})
        reconciled
      [] ->
        case system_recovery(user, p) do
          :ok ->
            [{^user, d}] = :ets.lookup(cache, user)
            reconcile_user_data(d, state.manifest)
          _ -> %{}
        end
    end

    dev_key = to_string(device_id)
    {seg_id, last_off} = case Map.get(user_data, dev_key) do
      {s, o} -> {s, o}
      nil ->
        old_seg = find_oldest_valid_segment(user_data, state.manifest)
        case get_in(user_data, ["positions", old_seg]) do
          {off, _phys} -> {old_seg, off - 1}
          _ -> {old_seg, 0}
        end
    end

    [base_str | _] = String.split(seg_id, "_")
    target_base = String.to_integer(base_str)

    {actual_seg_base, actual_phys} = case get_in(user_data, ["positions", seg_id]) do
      {_l_off, p_off} when is_integer(p_off) -> {target_base, p_off}
      _ ->
        gate = if last_off > 0, do: last_off - rem(last_off, @user_stride), else: 0
        case :ets.lookup(idx_cache(state.shard), {user, p, gate}) do
          [{_, {^target_base, pos}}] -> {target_base, pos}
          _ -> {target_base, 0}
        end
    end

    {:ok, disk_results} = stream_messages(state, user, p, actual_seg_base, actual_phys, batch_size, [], dev_key, last_off)

    buffer_tab = log_buffer(state.shard)
    raw_buffer = :ets.select(buffer_tab, [
      {{:"$1", {state.shard, :"$2", %{u: user, p: p, bin: :"$3", off: :"$4", writer_device: :"$5"}}}, [{:>, :"$4", last_off}, {:"/=", :"$5", dev_key}], [{{:"$3", :"$4", :"$5"}}]}
    ])

    unflushed_results = Enum.map(raw_buffer, fn {bin, offset, writer_dev} ->
      %{u: user, off: offset, writer_device: writer_dev, data: :erlang.binary_to_term(bin)}
    end)

    combined = (disk_results ++ unflushed_results)
               |> Enum.uniq_by(fn msg -> msg.off end)
               |> Enum.filter(fn msg -> msg.off > last_off end)
               |> Enum.sort_by(fn msg -> msg.off end)
               |> Enum.take(batch_size)

    {:reply, {:ok, Enum.map(combined, fn msg -> msg.data end)}, state}
  end

  defp stream_messages(state, user, p, seg_id, phys_pos, count, acc, device_id, last_off) do
    if count <= 0 do
      {:ok, Enum.reverse(acc)}
    else
      case read_from_disk(state, seg_id, phys_pos) do
        {:ok, rec, next_pos} ->
          user_str = to_string(user)
          if rec.u == user_str and rec.p == p and rec.off > last_off and to_string(rec.writer_device) != device_id do
            stream_messages(state, user, p, seg_id, next_pos, count - 1, [rec | acc], device_id, last_off)
          else
            stream_messages(state, user, p, seg_id, next_pos, count, acc, device_id, last_off)
          end
        {:error, :eof} ->
          case find_next_segment(state, seg_id) do
            {:ok, next} -> stream_messages(state, user, p, next, 0, count, acc, device_id, last_off)
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
      case String.split(filename, "_") do [_, b, _] -> [String.to_integer(b) | acc]; _ -> acc end
    end) |> Enum.sort()
    case Enum.find(bases, &(&1 > current_base)) do nil -> :no_more_segments; next_base -> {:ok, next_base} end
  end

  def load_manifest(shard) do
    path = Path.join(@base_dir, "#{shard}/#{shard}.manifest")
    if File.exists?(path) do
      data = :erlang.binary_to_term(File.read!(path))
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

  defp try_load_user(shard, path, user) do
    case Queue.FDPoolShard.read_bin(shard, path) do
      {:ok, binary} when binary != <<>> ->
        try do
          all_data = :erlang.binary_to_term(binary)
          case Map.get(all_data, user) do nil -> {:error, :not_found}; data -> {:ok, data} end
        rescue _ -> {:error, :corrupted} end
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
    else :already_loaded end
  end

 defp perform_recovery(user, partition_id, cache, data) do
    shard = :erlang.phash2(user, @num_shards)
    prime_indexes(shard, user, data, get_manifest_cached(shard))
    :ok
  end

  defp drain_buf(buf, state, _continuation \\ nil) do
    u_offsets = user_offsets_tab(state.shard)
    last_ptr = :ets.lookup_element(u_offsets, {:last_shard_offset, state.shard}, 2)
    current_head = :ets.lookup_element(u_offsets, {:shard_offset, state.shard}, 2)

    start_idx = last_ptr + 1
    end_idx = min(start_idx + @stable_limit - 1, current_head)

    if start_idx > current_head do finish_flush(state)
    else
      {items, last_processed_idx} = Enum.reduce_while(start_idx..end_idx, {[], last_ptr}, fn i, {acc, _prev} ->
        case :ets.lookup(buf, i) do
          [{^i, {shard, offset, record}}] -> :ets.delete(buf, i); {:cont, {[{{shard, offset, i}, record} | acc], i}}
          [] -> {:halt, {acc, i - 1}}
        end
      end)

      if items == [] do finish_flush(state)
      else
        :ets.insert(u_offsets, {{:last_shard_offset, state.shard}, last_processed_idx})
        new_state = process_batch(state, Enum.reverse(items), 0)
        snapshot_bin(new_state)
        if :ets.first(buf) != :"$end_of_table" do
          drain_buf(buf, new_state)
        else
          :file.datasync(state.log_fd); :file.datasync(state.idx_fd)
          finish_flush(new_state)
        end
      end
    end
  end

  defp get_manifest_cached(shard) do
    case :ets.lookup(user_offsets_tab(shard), :manifest_snapshot) do
      [{:manifest_snapshot, manifest}] -> manifest
      [] -> load_manifest(shard)
    end
  end

  @impl true
  def handle_info(:flush, state) do
    shard = state.shard; buf = log_buffer(shard)
    is_busy = case :ets.lookup(@flush_state, shard) do [{^shard, {:busy, pid}}] -> Process.alive?(pid); _ -> false end
    if is_busy do {:noreply, state}
    else
      :ets.insert(@flush_state, {shard, {:busy, self()}})
      try do {:noreply, drain_buf(buf, state)}
      rescue e -> Logger.error("Flush Crash: #{inspect(e)}"); :ets.insert(@flush_state, {shard, :idle}); schedule_flush(); {:noreply, state} end
    end
  end

  defp finish_flush(state) do
    :ets.insert(@flush_state, {state.shard, :idle}); schedule_flush(); state
  end

  @impl true
  def handle_cast(:trigger_maintenance, state) do
    shard = state.shard

    # 1. 🚀 PID-Aware Lock Validation
    is_busy = case :ets.lookup(@flush_state, shard) do
      [{^shard, {:busy, pid}}] -> Process.alive?(pid)
      [{^shard, :busy}] -> true
      _ -> false
    end

    if is_busy do
      Logger.warning("Shard #{shard} maintenance skipped: BUSY (Lock held by active process)")
      {:noreply, state}
    else
      # 2. Acquire Lock with current PID
      :ets.insert(@flush_state, {shard, {:busy, self()}})

      try do
        # 3. Get manifest from ETS
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

          # 5. Perform the move (The "Remove List/Compact" heavy lifting)
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
        # 7. 🛡️ Safety Release: Always set back to idle
        :ets.insert(@flush_state, {shard, :idle})
      end
    end
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

  def acknowledge(user, device_id, last_seen_offset) do
    shard = :erlang.phash2(user, @num_shards)
    GenServer.cast(worker_name(shard), {:ack, user, to_string(device_id), last_seen_offset})
  end

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
      # :ets.insert(cache, {user, new_user_data})
      Logger.info("Created new bookmark record for user: #{user} via Ack")
  end

  {:noreply, state}
end

defp find_segment_for_offset(positions, ack_offset, active_base) do
  positions
  |> Enum.reduce(nil, fn {seg_key, _}, acc ->
    {base_num, _} = Integer.parse(seg_key)

    # Check if this base is a valid candidate (<= ack_offset)
    if base_num <= ack_offset do
      case acc do
        # If it's the first candidate or closer to ack_offset than the previous best
        nil -> {seg_key, base_num}
        {_, best_val} when base_num > best_val -> {seg_key, base_num}
        _ -> acc
      end
    else
      acc
    end
  end)
  |> case do
    {seg_id, _} -> seg_id
    nil -> "#{active_base}"
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

  defp user_offsets_tab(s), do: :"#{@user_offsets_prefix}#{s}"
  defp checkpoints_tab(s), do: :"#{@checkpoints_prefix}#{s}"
  defp user_segment_counts_tab(s), do: :"#{@user_segment_counts_prefix}#{s}"
  defp log_buffer(s), do: :"#{@log_buffer_prefix}#{s}"
  defp idx_cache(s), do: :"#{@idx_cache_prefix}#{s}"
  defp worker_name(s), do: :"bimip_shard_#{s}"
  defp schedule_flush, do: Process.send_after(self(), :flush, @flush_interval + :rand.uniform(10_000))
end
