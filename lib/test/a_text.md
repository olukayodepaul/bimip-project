

shard_14_1768123478.log
shard_14_1768123523.log
log_path = "data/bimip/shard_14_1768150305.log"
case File.read(log_path) do
  {:ok, binary} ->
    # Recursive function to walk the binary
    parse_log = fn 
      recursive, <<0xEE, size::32, _crc::32, ulen::16, dlen::16, ts::64, rest::binary>> ->
        <<user::binary-size(ulen), device::binary-size(dlen), p::32, off::64, body::binary-size(size), next::binary>> = rest
        
        IO.puts "------------------------------------------------"
        IO.puts "📜 OFFSET: #{off} | USER: #{user} | TIME: #{ts}"
        # Decodes the actual message data
        IO.inspect(:erlang.binary_to_term(body), label: "Payload")
        
        recursive.(recursive, next)
      
      _, <<>> -> IO.puts "\n🏁 End of Log reached."
      _, _ -> IO.puts "⚠️ Partial or corrupt packet at end of file."
    end

    parse_log.(parse_log, binary)

  {:error, reason} -> IO.puts "Could not open log: #{reason}"
end





shard_14_1768123478.idx
shard_14_1768123523.idx
idx_path = "data/bimip/shard_14_1768151796.idx"
case File.read(idx_path) do
  {:ok, binary} ->
    parse_idx = fn
      recursive, <<ulen::16, user_bin::binary-size(ulen), p::32, off::64, seg::64, phys::64, rest::binary>> ->
        IO.puts "📍 [#{user_bin}] Offset: #{off} | Seg: #{seg} | Pos: #{phys} bytes"
        recursive.(recursive, rest)
      
      _, <<>> -> IO.puts "🏁 End of Index."
      _, rest -> 
        IO.puts "⚠️ Index contains partial entry. Remaining bytes: #{byte_size(rest)}"
    end

    parse_idx.(parse_idx, binary)

  {:error, reason} -> IO.puts "Could not open index: #{reason}"
end







manifest_path = "data/bimip/shard_14.manifest"
case File.read(manifest_path) do
  {:ok, binary} ->
    try do
      data = :erlang.binary_to_term(binary)
      IO.puts "📜 Manifest Content: #{inspect(data)}"
      
      # Link it to the files on disk
      if Map.has_key?(data, :active_base) do
        IO.puts "🎯 Current Active Segment: shard_14_#{data.active_base}.log"
      end
    rescue
      _ -> IO.puts "❌ Error: File is not a valid Erlang term."
    end

  {:error, reason} -> 
    IO.puts "Could not open manifest: #{reason}"
end

bookmark_path = "data/device_bookmarks/shard_14.bin"
binary = File.read!(bookmark_path)
entries = :erlang.binary_to_term(binary)
IO.inspect(entries, label: "📱 Device Bookmarks in Shard 14")

bookmark_path = "data/bimip/shard_14_1768150305.idx"
binary = File.read!(bookmark_path)
entries = :erlang.binary_to_term(binary)
IO.inspect(entries, label: "📱 Device Bookmarks in Shard 14")
