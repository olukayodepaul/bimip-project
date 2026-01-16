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



Queue.QueueLogImpl.system_recovery("user57@domain.com")
Queue.QueueLogImpl.system_recovery("user1@domain.com")
:ets.tab2list(:device_bookmarks_cache_37)

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



