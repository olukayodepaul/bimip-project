log_path = "data/bimip/shard_14_1768113319.log"

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






idx_path = "data/bimip/shard_14_1768113319.idx"
case File.read(idx_path) do
  {:ok, binary} ->
    parse_idx = fn
      recursive, <<ulen::16, user_bin::binary-size(ulen), _p::32, off::64, phys::64, rest::binary>> ->
        IO.puts "📍 [#{user_bin}] Offset: #{off} -> Pos: #{phys} bytes"
        recursive.(recursive, rest)
      
      _, <<>> -> IO.puts "🏁 End of Index."
      _, _ -> IO.puts "⚠️ Index contains partial entry."
    end

    parse_idx.(parse_idx, binary)

  {:error, reason} -> IO.puts "Could not open index: #{reason}"
end




bin_path = "data/device_bookmarks/shard_14.bin"

case File.read(bin_path) do
  {:ok, <<>>} -> 
    IO.puts("⚠️ File is empty (0 bytes). No flush has happened yet.")
    
  {:ok, bin} -> 
    try do
      anchors = :erlang.binary_to_term(bin)
      IO.inspect(anchors, label: "📍 Current Anchors")
    rescue
      _ -> IO.puts("❌ File contains data, but it's not a valid Erlang term.")
    end

  {:error, reason} -> 
    IO.puts("❌ Could not open file: #{reason}")
end