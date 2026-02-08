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
      file_ts = data.active_ts
      global_offset = Map.get(data, :msg_count, 0) 
      
      # 🚀 THE ADDITION: Get the Physical Pointer
      last_phys_pos = Map.get(data, :last_pos, 0)
      
      # Relative count in the current segment
      current_count = if global_offset >= base, do: (global_offset - base) + 1, else: 0
      
      # Calculate average message size for health monitoring
      avg_size = if current_count > 0, do: Float.round(last_phys_pos / current_count, 2), else: 0

      IO.puts "🎯 ACTIVE SEGMENT:"
      IO.puts "   Base Offset:     #{base}"
      IO.puts "   Global Offset:   #{global_offset}"
      IO.puts "   Msg in Segment:  #{current_count}"
      IO.puts "   Physical Pos:    #{last_phys_pos} bytes 📍"
      IO.puts "   Avg Msg Size:    #{avg_size} bytes"
      IO.puts "   File TS:         #{file_ts}"
      
      IO.puts "------------------------------------------------"
      
      if data.expired == %{} do
        IO.puts "📂 EXPIRED SEGMENTS: None"
      else
        IO.puts "📂 EXPIRED SEGMENTS:"
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


Queue.QueueLogImpl.system_recovery("user57@domain.com", 1)
Queue.QueueLogImpl.system_recovery("user1@domain.com", 1)
Queue.QueueLogImpl.system_recovery("user30@domain.com", 1)
Queue.QueueLogImpl.acknowledge("user57@domain.com", 2, 5)
{:ok, messages} = Queue.QueueLogImpl.fetch_batch("user57@domain.com", 1, 2, 20)
 {:ok, messages} = Queue.QueueLogImpl.fetch_batch("user1@domain.com", "partition", "device_id", 20)


:ets.tab2list(:device_bookmarks_cache_37)
:ets.tab2list(:bimip_user_offsets_37)

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