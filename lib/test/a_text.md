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
      file = data.active_ts
      # This is the Global Offset from your record
      global_offset = Map.get(data, :msg_count, 0) 
      
      # Calculate the count relative to the current file
      # If global is 0 (new file), count is 0. 
      # Otherwise, it's (Global - Base) + 1
      current_count = if global_offset > 0, do: (global_offset - base) + 1, else: 0
      
      IO.puts "🎯 ACTIVE SEGMENT:"
      IO.puts "   Base Offset:     #{base}"
      IO.puts "   Global Offset:   #{global_offset}"
      IO.puts "   File:   #{file}"
      
      IO.puts "------------------------------------------------"
      
      if data.expired == %{} do
        IO.puts "📂 EXPIRED SEGMENTS: None"
      else
        IO.puts "📂 EXPIRED SEGMENTS:"
        # Sort by rotation timestamp to see history in order
        Enum.sort_by(data.expired, fn {_, death_ts} -> death_ts end)
        |> Enum.each(fn {name_parts, death_ts} ->
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
folder_path = "data/bimip/#{shard}"
log_files = Path.wildcard("#{folder_path}/#{shard}_*.log") |> Enum.sort()

IO.puts "📜 Found #{Enum.count(log_files)} log files in #{folder_path}\n"

Enum.each(log_files, fn path ->
  IO.puts "================================================"
  IO.puts "📄 LOG FILE: #{Path.basename(path)}"
  
  case File.read(path) do
    {:ok, binary} ->
      parse_log = fn
        recursive, <<0xEE, body_size::32, crc::32, ulen::16, dlen::16, ts::64, rest::binary>>, count ->
          # Extract dynamic length strings and data
          <<user::binary-size(ulen), device::binary-size(dlen), p::32, off::64, body::binary-size(body_size), next::binary>> = rest
          
          # Attempt to decode the Erlang term
          payload = try do
            :erlang.binary_to_term(body)
          rescue
            _ -> "⚠️ [Could not decode Erlang term]"
          end

          IO.puts "📝 Entry ##{count}"
          IO.puts "   👤 User: #{user} | 📱 Device: #{device}"
          IO.puts "   🔢 Partition: #{p} | 🆔 Offset: #{off}"
          IO.puts "   🕒 TS: #{ts} | 📦 CRC: #{crc}"
          IO.puts "   --------------------------------------------"
          
          recursive.(recursive, next, count + 1)

        _, <<>>, count -> 
          IO.puts "🏁 End of log reached. Total records: #{count}"

        _, rest, count -> 
          IO.puts "⚠️ Trailing/Corrupt data: #{byte_size(rest)} bytes remaining. Total valid: #{count}"
      end

      parse_log.(parse_log, binary, 1)

    {:error, reason} -> 
      IO.puts "❌ Could not read log: #{reason}"
  end
end)

Queue.QueueLogImpl.system_recovery("user57@domain.com", 1)
Queue.QueueLogImpl.system_recovery("user1@domain.com", 1)
:ets.tab2list(:device_bookmarks_cache_37)
:ets.tab2list(:bimip_user_offsets_37)

  {{"user1@domain.com", 0}, 40},
  {{"user57@domain.com", 0}, 40}

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







