shard = 37
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
      IO.puts "   File:        #{base}"
      
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



shard = 37
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


shard = 37
bookmark_path = "data/device_bookmarks/#{shard}.bin"

case File.read(bookmark_path) do
  {:ok, binary} when binary != <<>> ->
    try do
      # This decodes the exact Erlang Term list stored in the file
      raw_entries = :erlang.binary_to_term(binary)
      
      IO.puts "\n" <> String.duplicate("=", 50)
      IO.puts "📂 RAW BINARY DUMP: SHARD #{shard}"
      IO.puts String.duplicate("=", 50)

      Enum.each(raw_entries, fn {user, data_map} ->
        IO.puts "\n👤 User: #{user}"
        IO.puts "📦 Raw Map Data:"
        
        # This will print the full Elixir map structure exactly as it exists
        IO.inspect(data_map, label: "   Content", structs: false)
        
        IO.puts "------------------------------------------------"
      end)
      
      IO.puts "\n✅ Total Raw Entries: #{Enum.count(raw_entries)}"

    rescue
      e -> IO.puts "❌ Error: Failed to decode binary term. #{inspect(e)}"
    end

  {:ok, <<>>} ->
    IO.puts "📁 The .bin file exists but is completely empty (0 bytes)."

  {:error, reason} -> 
    IO.puts "❌ Could not find or read file: #{bookmark_path} (#{reason})"
end

{
"__anchor__" => {"2001_1768572411", 1500},
 "positions" => %{
    "1_1768572326" => 1,
    "1001_1768572328" => 501, 
    "2001_1768572411" => 1001
  }
}



defmodule Queue.QueueLogImpl do
  @moduledoc """
  BimipLog v10.8 — Fixed Stride logic by persisting user_counts in State.
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
  @max_messages_per_seg 1000
  @user_stride 100
  @max_buffer_per_shard 1_000_000

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
    shard_dir = Path.join(@base_dir, "#{shard}")
    File.mkdir_p!(shard_dir)
    File.mkdir_p!("data/device_bookmarks")

    bin_path = Path.join("data/device_bookmarks", "#{shard}.bin")

    # 1. First, restore global offsets into ETS
    recover_counters_from_anchor(shard, bin_path)

    manifest = load_manifest(shard)
    base = manifest.active_base
    ts = manifest.active_ts

    # 2. NEW: Derive the stride counts using the recovered ETS and manifest base
    recovered_user_counts = recover_user_stride_counts(shard, base)

    recovered_msg_count = calculate_current_count(shard, base)

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
      active_base: base, active_ts: ts,
      user_counts: recovered_user_counts # 3. NOW RESTORED
    }}
  end

  defp recover_user_stride_counts(shard, active_base) do
    :ets.tab2list(@user_offsets)
    |> Enum.filter(fn {{user, _p}, _off} ->
      :erlang.phash2(user, @num_shards) == shard
    end)
    |> Enum.reduce(%{}, fn {{user, _partition}, off}, acc ->
      count_in_seg = off - (active_base - 1)
      final_count = if count_in_seg < 0, do: 0, else: count_in_seg
      Map.put(acc, user, final_count)
    end)
  end

  @impl true
  def handle_call(:force_flush, _from, state) do
    new_state = perform_flush(state)
    {:reply, :ok, new_state}
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

  @impl true
  def handle_info(:flush, state) do
    new_state = perform_flush(state)
    schedule_flush()
    {:noreply, new_state}
  end

  # -------------------- RECURSIVE FLUSH --------------------
  defp perform_flush(state) do
    buf = log_buffer(state.shard)
    items = :ets.take(buf, state.shard)

    if items == [] do
      state
    else
      sorted_items = Enum.sort_by(items, fn {_s, off, _rec} -> off end)
      process_batch(state, sorted_items)
    end
  end

  defp process_batch(state, items, depth \\ 0)
  defp process_batch(state, [], _depth), do: state

  defp process_batch(state, items, depth) when depth > 500 do
    Logger.error("Max recursion depth reached. Re-inserting #{length(items)} leftovers.")
    buf = log_buffer(state.shard)
    :ets.insert(buf, items)
    state
  end

  defp process_batch(state, items, depth) do
    space_left = @max_messages_per_seg - state.msg_count
    {to_write, leftovers} = Enum.split(items, space_left)

    # Use state.user_counts instead of an empty map %{}
    {bin_io, idx_io, final_count, final_bytes, updates, latest_map, next_user_counts} =
      Enum.reduce(to_write, {[], [], state.msg_count, state.current_size, [], %{}, state.user_counts},
        fn {_s, off, rec}, {b_acc, i_acc, curr_idx, curr_phys, upd, l_map, u_counts} ->

          {bin_packet, p_size} = encode_packet(rec, off, state)

          # Get current user's count in this segment
          u_count = Map.get(u_counts, rec.u, 0)

          {new_i_acc, new_upd} =
            if rem(u_count, @user_stride) == 0 do
              u_bin = to_string(rec.u)

              idx_entry = <<byte_size(u_bin)::16, u_bin::binary, rec.p::32, off::64, state.active_base::64, curr_phys::64>>
              :ets.insert(idx_cache(state.shard), {{rec.u, rec.p, off}, {state.active_base, curr_phys}})

              # PASS LOGICAL OFFSET (off)
              {[i_acc | idx_entry], [{rec.u, off} | upd]}
            else
              {i_acc, upd}
            end

          # Track the absolute last offset for every user in this batch
          updated_l_map = Map.put(l_map, rec.u, off)

          updated_u_counts = Map.put(u_counts, rec.u, u_count + 1)
          {[b_acc | bin_packet], new_i_acc, curr_idx + 1, curr_phys + p_size, new_upd, updated_l_map, updated_u_counts}
        end)

    :file.write(state.log_fd, bin_io)
    :file.write(state.idx_fd, idx_io)
    :file.datasync(state.log_fd)
    :file.datasync(state.idx_fd)

    # Global anchor: highest offset
    global_max_offset = latest_map |> Map.values() |> Enum.max()
    Enum.each(Map.keys(latest_map), fn user ->
      Queue.DeviceBookmark.mark_anchor(user, "#{state.active_base}_#{state.active_ts}", global_max_offset)
    end)

    # Sparse positions per user
    Enum.each(updates, fn {user, pos} ->
      Queue.DeviceBookmark.mark_position(user, "#{state.active_base}_#{state.active_ts}", pos)
    end)

    # Update state with the new user_counts
    new_state = %{state | msg_count: final_count, current_size: final_bytes, user_counts: next_user_counts}

    if new_state.msg_count >= @max_messages_per_seg do
      spawn(fn -> snapshot_bin(new_state) end)
      rotated_state = rotate_segment(new_state)
      process_batch(rotated_state, leftovers, depth + 1)
    else
      process_batch(new_state, leftovers, depth + 1)
    end
  end

  # -------------------- BIN SNAPSHOT --------------------
  defp snapshot_bin(state) do
    cache = :"device_bookmarks_cache_#{state.shard}"
    if :ets.info(cache) != :undefined do
      bookmark_data = :ets.tab2list(cache)
      bin = :erlang.term_to_binary(bookmark_data, [:compressed])
      bin_path = Path.join("data/device_bookmarks", "#{state.shard}.bin")
      tmp_path = bin_path <> ".tmp"
      File.write!(tmp_path, bin)
      File.rename!(tmp_path, bin_path)
    end
    :ok
  end

  # -------------------- PACKET ENCODING --------------------
  defp encode_packet(rec, offset, state) do
    u_bin = to_string(rec.u)
    d_bin = to_string(rec.writer_device)
    packet = [
      <<0xEE, byte_size(rec.bin)::32, :erlang.crc32(rec.bin)::32, byte_size(u_bin)::16, byte_size(d_bin)::16, rec.ts::64>>,
      u_bin,
      d_bin,
      <<rec.p::32, offset::64>>,
      rec.bin
    ]
    {packet, IO.iodata_length(packet)}
  end

  # -------------------- SEGMENT ROTATION --------------------
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

    l_path = Path.join(state.shard_dir, "#{state.shard}_#{new_base}_#{new_ts}.log")
    i_path = Path.join(state.shard_dir, "#{state.shard}_#{new_base}_#{new_ts}.idx")

    {:ok, l} = :file.open(l_path, [:append, :raw, :binary, :read, :write])
    {:ok, i} = :file.open(i_path, [:append, :raw, :binary, :read, :write])

    # RESET user_counts for the new file
    %{state | log_fd: l, idx_fd: i, active_base: new_base, active_ts: new_ts,
      current_size: 0, msg_count: 0, user_counts: %{}}
  end

  # ... (Remaining stream_messages, read_from_disk etc. remain unchanged)

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
            :erlang.binary_to_term(binary)
            |> Enum.each(fn
              {user, %{"__anchor__" => {_, off}}} ->
                :ets.insert(@user_offsets, {{user, 1}, off})
              _ -> :ok
            end)
          rescue _ -> :ok
          end
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
    snapshot_bin(state)
    :file.close(state.log_fd)
    :file.close(state.idx_fd)
    :file.close(state.bin_fd)
    :ok
  end
end
