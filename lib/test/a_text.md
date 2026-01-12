

shard_14_1768123478.log
shard_14_1768123523.log
log_path = "data/bimip/shard_14_454_1768230432.log"
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


log_path = "data/bimip/shard_14_454_1768230432.log"

case File.read(log_path) do
  {:ok, <<0xEE, size::32, _crc::32, ulen::16, dlen::16, ts::64, rest::binary>>} ->
    <<user::binary-size(ulen), device::binary-size(dlen), p::32, off::64, body::binary-size(size), _next::binary>> = rest
    
    IO.puts "✅ FIRST RECORD FOUND IN FILE"
    IO.puts "------------------------------------------------"
    IO.puts "📜 OFFSET: #{off}"
    IO.puts "👤 USER:   #{user}"
    IO.puts "🕒 TIME:   #{ts}"
    IO.inspect(:erlang.binary_to_term(body), label: "📦 Payload")
    
  {:ok, <<>>} -> 
    IO.puts "📁 File is empty."
  {:error, reason} -> 
    IO.puts "❌ Error: #{reason}"
end


shard_14_1768123478.idx
shard_14_1768123523.idx
idx_path = "data/bimip/shard_14_454_1768230432.idx"
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







manifest_path = "data/bimip/shard_14/shard_14.manifest"
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

Manifest Content: %{expired: %{}, active_base: 1, active_ts: 1768258619}
Manifest Content: %{expired: %{"1_1768258619" => 1768258687}, active_base: 101, active_ts: 1768258687}

bookmark_path = "data/device_bookmarks/shard_14.bin"
binary = File.read!(bookmark_path)
entries = :erlang.binary_to_term(binary)
IO.inspect(entries, label: "📱 Device Bookmarks in Shard 14")

bookmark_path = "data/bimip/shard_14_1768150305.idx"
binary = File.read!(bookmark_path)
entries = :erlang.binary_to_term(binary)
IO.inspect(entries, label: "📱 Device Bookmarks in Shard 14")








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

  # --- Manifest Helpers ---

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