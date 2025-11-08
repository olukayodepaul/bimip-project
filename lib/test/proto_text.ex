defmodule ProtoTest do
  def test() do
    binary =
      "
08 07 3A 4A 0A 01 33 10 02 18 02 20 01 28 C2 AF
AA 9D A6 33 32 16 0A 0C 61 40 64 6F 6D 61 69 6E
2E 63 6F 6D 12 06 61 61 61 61 61 31 3A 16 0A 0C
62 40 64 6F 6D 61 69 6E 2E 63 6F 6D 12 06 62 62
62 62 62 31 40 02 52 00 58 01 62 02 08 01
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