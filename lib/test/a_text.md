shard = 14
folder_path = "data/bimip/#{shard}"

# 1. Find ALL index files in the shard folder and sort them by name
idx_files = Path.wildcard("#{folder_path}/#{shard}_*.idx") |> Enum.sort()

if idx_files == [] do
  IO.puts "❌ No index files found in #{folder_path}"
else
  IO.puts "📚 Found #{Enum.count(idx_files)} index files. Processing...\n"

  Enum.each(idx_files, fn idx_path ->
    IO.puts "===================================================="
    IO.puts "📂 OPENING INDEX: #{Path.basename(idx_path)}"
    IO.puts "===================================================="

    case File.read(idx_path) do
      {:ok, binary} ->
        parse_idx = fn
          recursive, <<ulen::16, user_bin::binary-size(ulen), _p::32, off::64, seg::64, phys::64, rest::binary>> ->
            IO.puts "📍 [#{user_bin}] Offset: #{off} | Seg: #{seg} | Pos: #{phys} bytes"
            recursive.(recursive, rest)
          
          _, <<>> -> 
            :ok
          
          _, rest -> 
            IO.puts "⚠️ Index contains partial entry. Remaining bytes: #{byte_size(rest)}"
        end

        parse_idx.(parse_idx, binary)
        IO.puts "\n🏁 Finished reading: #{Path.basename(idx_path)}\n"

      {:error, reason} -> 
        IO.puts "❌ Could not open index #{idx_path}: #{reason}"
    end
  end)

  IO.puts "✅ All index files for Shard #{shard} have been read."
end

================ MANIFEST =================================

shard = 14
manifest_path = "data/bimip/#{shard}/#{shard}.manifest"

case File.read(manifest_path) do
  {:ok, binary} ->
    try do
      data = :erlang.binary_to_term(binary)
      IO.puts "================================================"
      IO.puts "📜 SHARD #{shard} MANIFEST SUMMARY"
      IO.puts "================================================"
      
      base = data.active_base
      ts = data.active_ts
      IO.puts "🎯 ACTIVE SEGMENT:"
      IO.puts "   Base Offset: #{base}"
      IO.puts "   Timestamp:   #{ts}"
      IO.puts data
      
      IO.puts "------------------------------------------------"
      
      if data.expired == %{} do
        IO.puts "📂 EXPIRED SEGMENTS: None"
      else
        IO.puts "📂 EXPIRED SEGMENTS:"
        Enum.each(data.expired, fn {name_parts, death_ts} ->
          # name_parts is "base_timestamp", filename needs shard prefix
          IO.puts "   • Segment: #{shard}_#{name_parts} | Rotated At: #{death_ts}"
        end)
      end
      IO.puts "================================================"
    rescue
      e -> IO.puts "❌ Error: Could not decode manifest term. #{inspect(e)}"
    end
  {:error, reason} -> IO.puts "❌ Could not open manifest: #{reason}"
end



shard = 14
base = 1
# Matches your preferred 14_1_*.idx format
[idx_path | _] = Path.wildcard("data/bimip/#{shard}/#{shard}_#{base}_*.idx")

case File.read(idx_path) do
  {:ok, binary} ->
    IO.puts "📂 Reading Index: #{idx_path}\n"
    parse_idx = fn
      recursive, <<ulen::16, user_bin::binary-size(ulen), _p::32, off::64, seg::64, phys::64, rest::binary>> ->
        IO.puts "📍 [#{user_bin}] Offset: #{off} | Seg: #{seg} | Pos: #{phys} bytes"
        recursive.(recursive, rest)
      _, <<>> -> IO.puts "\n🏁 End of Index."
      _, rest -> IO.puts "⚠️ Index contains partial entry. Remaining bytes: #{byte_size(rest)}"
    end
    parse_idx.(parse_idx, binary)
  {:error, reason} -> IO.puts "❌ Could not open index: #{reason}"
end




shard = 14
folder_path = "data/bimip/#{shard}"
idx_files = Path.wildcard("#{folder_path}/#{shard}_*.idx") |> Enum.sort()

IO.puts "📚 Found #{Enum.count(idx_files)} index files in #{folder_path}\n"

Enum.each(idx_files, fn path ->
  IO.puts "------------------------------------------------"
  IO.puts "📂 FILE: #{Path.basename(path)}"
  
  case File.read(path) do
    {:ok, binary} ->
      parse_idx = fn
        recursive, <<ulen::16, user_bin::binary-size(ulen), _p::32, off::64, seg::64, phys::64, rest::binary>> ->
          IO.puts "📍 [#{user_bin}] Offset: #{off} | Seg: #{seg} | Pos: #{phys} bytes"
          recursive.(recursive, rest)
        _, <<>> -> IO.puts "🏁 End of file reached."
        _, rest -> IO.puts "⚠️ Partial entry: #{byte_size(rest)} bytes remaining."
      end
      parse_idx.(parse_idx, binary)
    {:error, reason} -> IO.puts "❌ Could not read file: #{reason}"
  end
end)



shard = 14
# ✅ Matches the new naming: data/device_bookmarks/14.bin
bookmark_path = "data/device_bookmarks/#{shard}.bin"

case File.read(bookmark_path) do
  {:ok, binary} when binary != <<>> ->
    try do
      # Decodes the list of {user, map} tuples from ETS
      entries = :erlang.binary_to_term(binary)
      
      IO.puts "================================================"
      IO.puts "📱 DEVICE BOOKMARKS: SHARD #{shard}"
      IO.puts "================================================"

      Enum.each(entries, fn {user, data} ->
        # Data is the map containing the "__anchor__" key
        case Map.get(data, "__anchor__") do
          {seg, off} ->
            IO.puts "👤 User: #{user}"
            IO.puts "   📍 Last Segment: #{seg}"
            IO.puts "   🏁 Last Offset:  #{off}"
            IO.puts "------------------------------------------------"
          _ -> 
            IO.puts "👤 User: #{user} | No Anchor Found"
        end
      end)
      
      IO.puts "✅ Total Bookmarked Users: #{Enum.count(entries)}"

    rescue
      e -> IO.puts "❌ Error: Invalid binary term in bookmark file. #{inspect(e)}"
    end

  {:ok, <<>>} ->
    IO.puts "📁 Bookmark file is empty."

  {:error, reason} -> 
    IO.puts "❌ Could not open bookmark file: #{reason} (Path: #{bookmark_path})"
end



====================================================
📂 OPENING INDEX: 14_1_1768423872.idx
====================================================
📍 [b@domain.com] Offset: 1 | Seg: 1 | Pos: 0 bytes
📍 [b@domain.com] Offset: 101 | Seg: 1 | Pos: 61276 bytes
📍 [b@domain.com] Offset: 201 | Seg: 1 | Pos: 122876 bytes
📍 [b@domain.com] Offset: 301 | Seg: 1 | Pos: 184611 bytes
📍 [b@domain.com] Offset: 401 | Seg: 1 | Pos: 246511 bytes
📍 [b@domain.com] Offset: 501 | Seg: 1 | Pos: 308411 bytes

🏁 Finished reading: 14_1_1768423872.idx

====================================================
📂 OPENING INDEX: 14_601_1768424145.idx
====================================================
📍 [b@domain.com] Offset: 601 | Seg: 601 | Pos: 0 bytes
📍 [b@domain.com] Offset: 701 | Seg: 601 | Pos: 61576 bytes
📍 [b@domain.com] Offset: 801 | Seg: 601 | Pos: 123476 bytes
📍 [b@domain.com] Offset: 901 | Seg: 601 | Pos: 185376 bytes
📍 [b@domain.com] Offset: 1001 | Seg: 601 | Pos: 247276 bytes



















defmodule Queue.QueueLogImpl do
  @moduledoc """
  BimipLog v10.1 — Sharded Append-Only Log with Per-Shard Directories.
  Structure: data/bimip/shard_{shard}/shard_{shard}_{baseOffset}_{timestamp}.log
  """
  use GenServer
  require Logger

  # ------------------------------------------------------------------
  # CONFIG
  # ------------------------------------------------------------------
  @base_dir "data/bimip"
  @num_shards 64
  @header_size 21
  @flush_interval 100
  @max_messages_per_seg 500
  @max_buffer_per_shard 1_000_000
  @user_stride 100

  @checkpoints :bimip_segment_checkpoints
  @user_offsets :bimip_user_offsets
  @idx_cache_prefix :"bimip_idx_"
  @log_buffer_prefix :"bimip_buf_"

  # ------------------------------------------------------------------
  # PUBLIC API
  # ------------------------------------------------------------------

  def start_link(shard), do: GenServer.start_link(__MODULE__, shard, name: worker_name(shard))

  def __startup__ do
    if :ets.info(@user_offsets) == :undefined, do: :ets.new(@user_offsets, [:named_table, :public, :set, {:write_concurrency, true}])
    if :ets.info(@checkpoints) == :undefined, do: :ets.new(@checkpoints, [:named_table, :public, :set, {:read_concurrency, true}])

    for s <- 0..(@num_shards - 1) do
      if :ets.info(log_buffer(s)) == :undefined, do: :ets.new(log_buffer(s), [:named_table, :public, :duplicate_bag, {:write_concurrency, true}])
      if :ets.info(idx_cache(s)) == :undefined, do: :ets.new(idx_cache(s), [:named_table, :public, :set, {:read_concurrency, true}])
    end
    :ok
  end

  def sync_flush(recipient_uid) do
    shard = :erlang.phash2(recipient_uid, @num_shards)
    GenServer.call(worker_name(shard), :force_flush, 15_000)
  end

  def write(partition_id, sender_uid, recipient_uid, device_id, type, payload_ctx, payload, message_id) do
    shard = :erlang.phash2(recipient_uid, @num_shards)
    buf = log_buffer(shard)

    if :ets.info(buf, :size) > @max_buffer_per_shard do
      {:error, :backpressure}
    else
      offset = :ets.update_counter(@user_offsets, {recipient_uid, partition_id}, {2, 1}, {{recipient_uid, partition_id}, 0})
      data = Queue.Persist.build(%{payload: payload}, offset, recipient_uid, type, payload_ctx)

      record = %{
        u: recipient_uid, s: sender_uid, p: partition_id, off: offset, mid: message_id,
        writer_device: to_string(device_id), bin: :erlang.term_to_binary(data),
        ts: System.system_time(:second)
      }

      :ets.insert(buf, {shard, offset, record})
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
    # ✅ Create Shard-Specific Directory
    shard_dir = Path.join(@base_dir, "shard_#{shard}")
    File.mkdir_p!(shard_dir)
    File.mkdir_p!("data/device_bookmarks")

    bin_path = Path.join("data/device_bookmarks", "shard_#{shard}.bin")
    recover_counters_from_anchor(shard, bin_path)

    manifest = load_manifest(shard)

    # ✅ Fix: Use .active_base and .active_ts to match load_manifest map keys
    base = manifest.active_base
    ts = manifest.active_ts

    recovered_msg_count = calculate_current_count(shard, base)

    # ✅ Paths use shard_dir
    log_path = Path.join(shard_dir, "shard_#{shard}_#{base}_#{ts}.log")
    idx_path = Path.join(shard_dir, "shard_#{shard}_#{base}_#{ts}.idx")

    {:ok, log_fd} = :file.open(log_path, [:append, :raw, :binary, :read, :write])
    {:ok, idx_fd} = :file.open(idx_path, [:append, :raw, :binary, :read, :write])
    {:ok, bin_fd} = :file.open(bin_path, [:append, :raw, :binary, :read, :write])

    # ✅ Fix: Pass the manifest map directly to write_manifest/2
    if not manifest.exists, do: write_manifest(shard, manifest)

    {:ok, actual_pos} = :file.position(log_fd, :cur)
    schedule_flush()

    {:ok, %{
      shard: shard, shard_dir: shard_dir, log_fd: log_fd, idx_fd: idx_fd, bin_fd: bin_fd,
      current_size: actual_pos, msg_count: recovered_msg_count,
      active_base: base, active_ts: ts
    }}
  end

  defp calculate_current_count(_shard, base) do
    case :ets.match(@user_offsets, {{:"$1", :"$2"}, :"$3"}) do
      [] -> 0
      matches ->
        max_off = Enum.reduce(matches, 0, fn [_, _, off], acc -> max(off, acc) end)
        if max_off >= base, do: max_off - (base - 1), else: 0
    end
  end

defp recover_counters_from_anchor(_shard, bin_path) do
    if File.exists?(bin_path) do
      case File.read(bin_path) do
        {:ok, binary} when binary != <<>> ->
          try do
            :erlang.binary_to_term(binary) |> Enum.each(fn
              # ✅ FIXED: Removed the 3rd variable from the anchor pattern match
              {user, %{"__anchor__" => {_, off}}} ->
                :ets.insert(@user_offsets, {{user, 1}, off})
              _ -> :ok
            end)
          rescue _ -> :ok end
        _ -> :ok
      end
    end
  end

  @impl true
  def handle_call(:force_flush, _from, state) do
    new_state = perform_flush(state)
    {:reply, :ok, new_state}
  end

  @impl true
  def handle_call({:fetch, user, p, device_id, batch_size}, _from, state) do
    # 1. Get the logical offset (Returns Integer)
    log_off = Queue.DeviceBookmark.get(device_id, user)

    # 2. Extract the Segment Name from the Bookmark Map
    # We must peek at the ETS because get/2 discards the segment info
    cache = :"device_bookmarks_cache_#{:erlang.phash2(user, @num_shards)}"
    seg_id = case :ets.lookup(cache, user) do
      [{^user, %{"__anchor__" => {seg, _}}}] -> seg
      _ -> state.active_base # Fallback to current shard segment
    end

    # 3. Sparse Index Logic
    gate_off = if log_off > 0, do: log_off - rem(log_off - 1, @user_stride), else: 0

    {actual_seg, actual_phys} = case :ets.lookup(idx_cache(state.shard), {user, p, gate_off}) do
      [{_, {s, pos}}] -> {s, pos}
      _ -> {seg_id, 0}
    end

    {:ok, disk_results} = stream_messages(state, user, p, actual_seg, actual_phys, batch_size, [], device_id)
    filtered = Enum.filter(disk_results, fn msg -> msg.off > log_off end)
    {:reply, {:ok, filtered}, state}
  end

  @impl true
  def handle_info(:flush, state) do
    new_state = perform_flush(state)
    schedule_flush()
    {:noreply, new_state}
  end

  # ------------------------------------------------------------------
  # INTERNAL LOGIC
  # ------------------------------------------------------------------
  defp perform_flush(state) do
      buf = log_buffer(state.shard)
      case :ets.take(buf, state.shard) do
        [] -> state
        items ->
          state = if state.msg_count >= @max_messages_per_seg, do: rotate_segment(state), else: state
          sorted = Enum.sort_by(items, fn {_shard, off, _rec} -> off end)

          {io_list, final_pos, final_msg_count, final_state} =
            Enum.reduce(sorted, {[], state.current_size, state.msg_count, state}, fn {_s, off, rec}, {acc_io, curr_p, acc_c, acc_s} ->

              # ✅ No mark_initializer (as requested)

              {packet, p_size, updated_s} = build_packet_data(acc_s, rec, off, curr_p)

              # ✅ STRICT ARITY 3: mark_anchor(user, segment, offset)
              # Partition (rec.p) is NOT passed here to match your module exactly.
              Queue.DeviceBookmark.mark_anchor(rec.u, updated_s.active_base, off)

              {[acc_io | packet], curr_p + p_size, acc_c + 1, updated_s}
            end)

          :file.write(final_state.log_fd, io_list)

          :file.datasync(final_state.log_fd)
          :file.datasync(final_state.idx_fd)

          bookmark_data = :ets.tab2list(:"device_bookmarks_cache_#{state.shard}")
          :file.pwrite(final_state.bin_fd, 0, :erlang.term_to_binary(bookmark_data))
          %{final_state | current_size: final_pos, msg_count: final_msg_count}
      end
  end

  defp rotate_segment(state) do
    # 1. Prepare the NEW active details
    new_base = state.active_base + state.msg_count
    new_ts = System.system_time(:second)

    # 2. Close descriptors for the segment that is about to retire
    :file.close(state.log_fd)
    :file.close(state.idx_fd)

    # 3. ATOMIC HAND-OFF: Move current details into the 'expired' map
    manifest = load_manifest(state.shard)
    expired_key = "#{state.active_base}_#{state.active_ts}"

    # We use the current 'new_ts' as the start of the death clock for the old file
    updated_expired_map = Map.put(manifest.expired, expired_key, new_ts)

    updated_manifest = %{
      active_base: new_base,
      active_ts: new_ts,
      expired: updated_expired_map
    }

    write_manifest(state.shard, updated_manifest)

    # 4. Open the new segment files
    l_path = Path.join(state.shard_dir, "shard_#{state.shard}_#{new_base}_#{new_ts}.log")
    i_path = Path.join(state.shard_dir, "shard_#{state.shard}_#{new_base}_#{new_ts}.idx")

    {:ok, l} = :file.open(l_path, [:append, :raw, :binary, :read, :write])
    {:ok, i} = :file.open(i_path, [:append, :raw, :binary, :read, :write])

    IO.puts "🔄 ROTATED: #{expired_key} moved to expired. New active: #{new_base}_#{new_ts}"

    %{state | log_fd: l, idx_fd: i, active_base: new_base, active_ts: new_ts, current_size: 0, msg_count: 0}
  end


  defp build_packet_data(state, rec, offset, curr_pos) do
    u_bin = to_string(rec.u)
    d_bin = to_string(rec.writer_device)
    packet = [<<0xEE, byte_size(rec.bin)::32, :erlang.crc32(rec.bin)::32, byte_size(u_bin)::16, byte_size(d_bin)::16, rec.ts::64>>, u_bin, d_bin, <<rec.p::32, offset::64>>, rec.bin]
    packet_size = IO.iodata_length(packet)

    if rem(offset, @user_stride) == 1 do
      index_entry = <<byte_size(u_bin)::16, u_bin::binary, rec.p::32, offset::64, state.active_base::64, curr_pos::64>>
      :ok = :file.write(state.idx_fd, index_entry)
      :ets.insert(idx_cache(state.shard), {{rec.u, rec.p, offset}, {state.active_base, curr_pos}})
    end

    :ets.insert(@checkpoints, {{state.shard, state.active_base}, {offset, curr_pos}})
    {packet, packet_size, state}
  end

  defp read_from_disk(state, base, pos) do
    # ✅ Search only within the shard's own folder
    case Path.wildcard(Path.join(state.shard_dir, "shard_#{state.shard}_#{base}_*.log")) do
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

        _ ->
          {:ok, Enum.reverse(acc)}
      end
    end
  end

  defp find_next_segment(state, current_base) do
    # Get all log files in this shard's directory
    files = Path.wildcard(Path.join(state.shard_dir, "shard_#{state.shard}_*.log"))

    bases = Enum.reduce(files, [], fn f, acc ->
      filename = Path.basename(f, ".log")
      parts = String.split(filename, "_")

      # Use Enum.at(parts, 2) which is the Base Offset in "shard_14_1_123.log"
      case Enum.at(parts, 2) do
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
    shard_dir = Path.join(@base_dir, "shard_#{shard}")
    path = Path.join(shard_dir, "shard_#{shard}.manifest")
    if File.exists?(path) do
      data = :erlang.binary_to_term(File.read!(path))
      %{
        active_base: data.active_base,
        active_ts: Map.get(data, :active_ts, System.system_time(:second)),
        expired: Map.get(data, :expired, %{}),
        exists: true
      }
    else
      %{active_base: 1, active_ts: System.system_time(:second), expired: %{}, exists: false}
    end
  end

  defp write_manifest(shard, manifest_data) do
    shard_dir = Path.join(@base_dir, "shard_#{shard}")
    path = Path.join(shard_dir, "shard_#{shard}.manifest")
    # Drop internal flags before saving to disk
    storage_map = Map.drop(manifest_data, [:exists])
    File.write!(path <> ".tmp", :erlang.term_to_binary(storage_map))
    File.rename!(path <> ".tmp", path)
  end

  defp log_buffer(s), do: :"#{@log_buffer_prefix}#{s}"
  defp idx_cache(s), do: :"#{@idx_cache_prefix}#{s}"
  defp worker_name(s), do: :"bimip_shard_#{s}"
  defp schedule_flush, do: Process.send_after(self(), :flush, @flush_interval)

  @impl true
  def terminate(_reason, state) do
    perform_flush(state)
    :file.close(state.log_fd)
    :file.close(state.idx_fd)
    :file.close(state.bin_fd)
    :ok
  end
end











defmodule Queue.QueueLogImpl do
  @moduledoc """
  BimipLog v10.2 — Clean Sharded Append-Only Log.
  Structure: data/bimip/{shard}/{shard}_{baseOffset}_{timestamp}.log
  """
  use GenServer
  require Logger

  # ------------------------------------------------------------------
  # CONFIG
  # ------------------------------------------------------------------
  @base_dir "data/bimip"
  @num_shards 64
  @header_size 21
  @flush_interval 100
  @max_messages_per_seg 500
  @max_buffer_per_shard 1_000_000
  @user_stride 100

  @checkpoints :bimip_segment_checkpoints
  @user_offsets :bimip_user_offsets
  @idx_cache_prefix :"bimip_idx_"
  @log_buffer_prefix :"bimip_buf_"

  # ------------------------------------------------------------------
  # PUBLIC API
  # ------------------------------------------------------------------

  def start_link(shard), do: GenServer.start_link(__MODULE__, shard, name: worker_name(shard))

  def __startup__ do
    if :ets.info(@user_offsets) == :undefined, do: :ets.new(@user_offsets, [:named_table, :public, :set, {:write_concurrency, true}])
    if :ets.info(@checkpoints) == :undefined, do: :ets.new(@checkpoints, [:named_table, :public, :set, {:read_concurrency, true}])

    for s <- 0..(@num_shards - 1) do
      if :ets.info(log_buffer(s)) == :undefined, do: :ets.new(log_buffer(s), [:named_table, :public, :duplicate_bag, {:write_concurrency, true}])
      if :ets.info(idx_cache(s)) == :undefined, do: :ets.new(idx_cache(s), [:named_table, :public, :set, {:read_concurrency, true}])
    end
    :ok
  end

  def sync_flush(recipient_uid) do
    shard = :erlang.phash2(recipient_uid, @num_shards)
    GenServer.call(worker_name(shard), :force_flush, 15_000)
  end

  def write(partition_id, sender_uid, recipient_uid, device_id, type, payload_ctx, payload, message_id) do
    shard = :erlang.phash2(recipient_uid, @num_shards)
    buf = log_buffer(shard)

    if :ets.info(buf, :size) > @max_buffer_per_shard do
      {:error, :backpressure}
    else
      offset = :ets.update_counter(@user_offsets, {recipient_uid, partition_id}, {2, 1}, {{recipient_uid, partition_id}, 0})
      data = Queue.Persist.build(%{payload: payload}, offset, recipient_uid, type, payload_ctx)

      record = %{
        u: recipient_uid, s: sender_uid, p: partition_id, off: offset, mid: message_id,
        writer_device: to_string(device_id), bin: :erlang.term_to_binary(data),
        ts: System.system_time(:second)
      }

      :ets.insert(buf, {shard, offset, record})
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
    # ✅ DIR: data/bimip/14/
    shard_dir = Path.join(@base_dir, "#{shard}")
    File.mkdir_p!(shard_dir)
    File.mkdir_p!("data/device_bookmarks")

    bin_path = Path.join("data/device_bookmarks", "shard_#{shard}.bin")
    recover_counters_from_anchor(shard, bin_path)

    manifest = load_manifest(shard)
    base = manifest.active_base
    ts = manifest.active_ts

    recovered_msg_count = calculate_current_count(shard, base)

    # ✅ FILE: 14_601_12345.log
    log_path = Path.join(shard_dir, "#{shard}_#{base}_#{ts}.log")
    idx_path = Path.join(shard_dir, "#{shard}_#{base}_#{ts}.idx")

    {:ok, log_fd} = :file.open(log_path, [:append, :raw, :binary, :read, :write])
    {:ok, idx_fd} = :file.open(idx_path, [:append, :raw, :binary, :read, :write])
    {:ok, bin_fd} = :file.open(bin_path, [:append, :raw, :binary, :read, :write])

    if not manifest.exists, do: write_manifest(shard, manifest)

    {:ok, actual_pos} = :file.position(log_fd, :cur)
    schedule_flush()

    {:ok, %{
      shard: shard, shard_dir: shard_dir, log_fd: log_fd, idx_fd: idx_fd, bin_fd: bin_fd,
      current_size: actual_pos, msg_count: recovered_msg_count,
      active_base: base, active_ts: ts
    }}
  end

  @impl true
  def handle_call(:force_flush, _from, state) do
    new_state = perform_flush(state)
    {:reply, :ok, new_state}
  end

  @impl true
  def handle_call({:fetch, user, p, device_id, batch_size}, _from, state) do
    log_off = Queue.DeviceBookmark.get(device_id, user)

    # Locate segment ID from cache or state
    cache = :"device_bookmarks_cache_#{state.shard}"
    seg_id = case :ets.lookup(cache, user) do
      [{^user, %{"__anchor__" => {seg, _}}}] -> seg
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

  @impl true
  def handle_info(:flush, state) do
    new_state = perform_flush(state)
    schedule_flush()
    {:noreply, new_state}
  end

  # ------------------------------------------------------------------
  # INTERNAL LOGIC
  # ------------------------------------------------------------------

  defp perform_flush(state) do
    buf = log_buffer(state.shard)
    case :ets.take(buf, state.shard) do
      [] -> state
      items ->
        state = if state.msg_count >= @max_messages_per_seg, do: rotate_segment(state), else: state
        sorted = Enum.sort_by(items, fn {_shard, off, _rec} -> off end)

        {io_list, final_pos, final_msg_count, final_state} =
          Enum.reduce(sorted, {[], state.current_size, state.msg_count, state}, fn {_s, off, rec}, {acc_io, curr_p, acc_c, acc_s} ->
            {packet, p_size, updated_s} = build_packet_data(acc_s, rec, off, curr_p)
            Queue.DeviceBookmark.mark_anchor(rec.u, updated_s.active_base, off)
            {[acc_io | packet], curr_p + p_size, acc_c + 1, updated_s}
          end)

        :file.write(final_state.log_fd, io_list)
        :file.datasync(final_state.log_fd)
        :file.datasync(final_state.idx_fd)

        bookmark_data = :ets.tab2list(:"device_bookmarks_cache_#{state.shard}")
        :file.pwrite(final_state.bin_fd, 0, :erlang.term_to_binary(bookmark_data))
        %{final_state | current_size: final_pos, msg_count: final_msg_count}
    end
  end

  defp rotate_segment(state) do
    new_base = state.active_base + state.msg_count
    new_ts = System.system_time(:second)

    :file.close(state.log_fd)
    :file.close(state.idx_fd)

    manifest = load_manifest(state.shard)
    expired_key = "#{state.active_base}_#{state.active_ts}"

    updated_manifest = %{
      active_base: new_base,
      active_ts: new_ts,
      expired: Map.put(manifest.expired, expired_key, new_ts)
    }

    write_manifest(state.shard, updated_manifest)

    # ✅ CLEAN FILENAMES: 14_601_1768419365.log
    l_path = Path.join(state.shard_dir, "#{state.shard}_#{new_base}_#{new_ts}.log")
    i_path = Path.join(state.shard_dir, "#{state.shard}_#{new_base}_#{new_ts}.idx")

    {:ok, l} = :file.open(l_path, [:append, :raw, :binary, :read, :write])
    {:ok, i} = :file.open(i_path, [:append, :raw, :binary, :read, :write])

    %{state | log_fd: l, idx_fd: i, active_base: new_base, active_ts: new_ts, current_size: 0, msg_count: 0}
  end

  defp build_packet_data(state, rec, offset, curr_pos) do
    u_bin = to_string(rec.u)
    d_bin = to_string(rec.writer_device)
    packet = [<<0xEE, byte_size(rec.bin)::32, :erlang.crc32(rec.bin)::32, byte_size(u_bin)::16, byte_size(d_bin)::16, rec.ts::64>>, u_bin, d_bin, <<rec.p::32, offset::64>>, rec.bin]
    packet_size = IO.iodata_length(packet)

    if rem(offset, @user_stride) == 1 do
      index_entry = <<byte_size(u_bin)::16, u_bin::binary, rec.p::32, offset::64, state.active_base::64, curr_pos::64>>
      :ok = :file.write(state.idx_fd, index_entry)
      :ets.insert(idx_cache(state.shard), {{rec.u, rec.p, offset}, {state.active_base, curr_pos}})
    end

    :ets.insert(@checkpoints, {{state.shard, state.active_base}, {offset, curr_pos}})
    {packet, packet_size, state}
  end

  defp read_from_disk(state, base, pos) do
    # ✅ MATCH CLEAN FILENAME
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

      # ✅ New Pattern: ["14", "601", "12345"] -> Index 1 is Base
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
      data = :erlang.binary_to_term(File.read!(path))
      %{
        active_base: data.active_base,
        active_ts: Map.get(data, :active_ts, System.system_time(:second)),
        expired: Map.get(data, :expired, %{}),
        exists: true
      }
    else
      %{active_base: 1, active_ts: System.system_time(:second), expired: %{}, exists: false}
    end
  end

  defp write_manifest(shard, manifest_data) do
    shard_dir = Path.join(@base_dir, "#{shard}")
    path = Path.join(shard_dir, "#{shard}.manifest")
    storage_map = Map.drop(manifest_data, [:exists])
    File.write!(path <> ".tmp", :erlang.term_to_binary(storage_map))
    File.rename!(path <> ".tmp", path)
  end

  # Helper logic
  defp calculate_current_count(_shard, base) do
    case :ets.match(@user_offsets, {{:"$1", :"$2"}, :"$3"}) do
      [] -> 0
      matches ->
        max_off = Enum.reduce(matches, 0, fn [_, _, off], acc -> max(off, acc) end)
        if max_off >= base, do: max_off - (base - 1), else: 0
    end
  end

  defp recover_counters_from_anchor(_shard, bin_path) do
    if File.exists?(bin_path) do
      case File.read(bin_path) do
        {:ok, binary} when binary != <<>> ->
          try do
            :erlang.binary_to_term(binary) |> Enum.each(fn
              {user, %{"__anchor__" => {_, off}}} ->
                :ets.insert(@user_offsets, {{user, 1}, off})
              _ -> :ok
            end)
          rescue _ -> :ok end
        _ -> :ok
      end
    end
  end

  defp log_buffer(s), do: :"#{@log_buffer_prefix}#{s}"
  defp idx_cache(s), do: :"#{@idx_cache_prefix}#{s}"
  defp worker_name(s), do: :"bimip_shard_#{s}"
  defp schedule_flush, do: Process.send_after(self(), :flush, @flush_interval)

  @impl true
  def terminate(_reason, state) do
    perform_flush(state)
    :file.close(state.log_fd)
    :file.close(state.idx_fd)
    :file.close(state.bin_fd)
    :ok
  end
end
