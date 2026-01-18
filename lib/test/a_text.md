shard = 0
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



shard = 0
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


Queue.QueueLogImpl.system_recovery("user1@domain.com")
Queue.QueueLogImpl.system_recovery("user1@domain.com")
:ets.tab2list(:device_bookmarks_cache_37)

shard = 0
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
    u_counts = user_segment_counts_tab(state.shard)

    {bin_io, idx_io, final_count, final_bytes, updates, latest_map} =
      Enum.reduce(to_write, {[], [], state.msg_count, state.current_size, [], %{}},
        fn {_s, off, rec}, {b_acc, i_acc, curr_idx, curr_phys, upd, l_map} ->
          {bin_packet, p_size} = encode_packet(rec, off, state)

          # ATOMIC INCREMENT IN SHARDED ETS
          u_count = :ets.update_counter(u_counts, rec.u, {2, 1}, {rec.u, 0})
          current_stride_check = u_count - 1

          {new_i_acc, new_upd} =
            if rem(current_stride_check, @user_stride) == 0 do
              u_bin = to_string(rec.u)
              idx_entry = <<byte_size(u_bin)::16, u_bin::binary, rec.p::32, off::64, state.active_base::64, curr_phys::64>>
              :ets.insert(idx_cache(state.shard), {{rec.u, rec.p, off}, {state.active_base, curr_phys}})
              {[i_acc | idx_entry], [{rec.u, off} | upd]}
            else
              {i_acc, upd}
            end

          updated_l_map = Map.put(l_map, rec.u, off)
          {[b_acc | bin_packet], new_i_acc, curr_idx + 1, curr_phys + p_size, new_upd, updated_l_map}
        end)

    :file.write(state.log_fd, bin_io)
    :file.write(state.idx_fd, idx_io)
    :file.datasync(state.log_fd)
    :file.datasync(state.idx_fd)

    global_max_offset = if Map.size(latest_map) > 0, do: latest_map |> Map.values() |> Enum.max(), else: 0
    Enum.each(Map.keys(latest_map), fn user ->
      Queue.DeviceBookmark.mark_anchor(user, "#{state.active_base}_#{state.active_ts}", global_max_offset)
    end)

    Enum.each(updates, fn {user, pos} ->
      Queue.DeviceBookmark.mark_position(user, "#{state.active_base}_#{state.active_ts}", pos)
    end)

    new_state = %{state | msg_count: final_count, current_size: final_bytes}

    if new_state.msg_count >= @max_messages_per_seg do
      snapshot_bin(new_state)
      rotated_state = rotate_segment(new_state)
      process_batch(rotated_state, leftovers, depth + 1)
    else
      process_batch(new_state, leftovers, depth + 1)
    end
  end