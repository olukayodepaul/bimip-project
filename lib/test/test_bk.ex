defmodule LogInspector do
  def inspect_shard(shard) do
    path = "data/bimip/#{shard}"
    log_files = Path.wildcard("#{path}/*.log") |> Enum.sort()

    Enum.each(log_files, fn path ->
      IO.puts "\n📄 FILE: #{Path.basename(path)}"
      IO.puts "ORDER | USER                      | BIN_HDR_OFF | SHARD_OFFSET  | OFFSET"
      IO.puts String.duplicate("-", 85)

      case File.read(path) do
        {:ok, binary} -> do_parse_log(binary, 1)
        {:error, reason} -> IO.puts "❌ Could not read: #{reason}"
      end
    end)
  end

  defp do_parse_log(<<
    0xEE,
    body_size::32, _crc::32, ulen::16, dlen::16, _ts::64,
    user::binary-size(ulen),
    _device_bin::binary-size(dlen),
    _p::32,
    bin_hdr_off::64,
    body::binary-size(body_size),
    next::binary
  >>, count) do

    payload = try do :erlang.binary_to_term(body) rescue _ -> %{} end

    # Try fetching as atoms first (standard for Elixir maps)
    shard_off = Map.get(payload, :shard_offset) || Map.get(payload, "shard_offset", "N/A")
    user_off  = Map.get(payload, :offset)       || Map.get(payload, "offset", "N/A")

    IO.puts "#{String.pad_leading("##{count}", 5)} | " <>
            "#{String.pad_trailing(user, 25)} | " <>
            "#{String.pad_leading("#{bin_hdr_off}", 11)} | " <>
            "#{String.pad_leading("#{shard_off}", 13)} | " <>
            "#{String.pad_leading("#{user_off}", 7)}"

    do_parse_log(next, count + 1)
  end

  defp do_parse_log(<<>>, _count), do: IO.puts "🏁 End of file."
  defp do_parse_log(rest, _count) when byte_size(rest) > 0, do: IO.puts "⚠️ Trailing: #{byte_size(rest)} bytes"
  defp do_parse_log(_, _count), do: :ok
end
# LogInspector.inspect_shard(37)

# Run it
# LogInspector.inspect_shard(0)
