defmodule ProtoTest do
  def test() do
    binary =
      "
08 02 12 51 0A 16 0A 0C 61 40 64 6F 6D 61 69 6E
2E 63 6F 6D 12 06 61 61 61 61 61 31 12 16 0A 0C
62 40 64 6F 6D 61 69 6E 2E 63 6F 6D 12 06 62 62
62 62 62 31 18 02 20 06 28 01 31 00 00 00 00 00
00 F0 3F 39 00 00 00 00 00 00 08 40 40 05 50 AC
EF 8B EB 9C 33    


      "
      |> String.split()
      |> Enum.map(&String.to_integer(&1, 16))
      |> :binary.list_to_bin()

    # Decode with MessageScheme|>
    message = Bimip.MessageScheme.decode(binary) 
    IO.inspect(message, label: "")

  end
end

# ProtoTest.test()