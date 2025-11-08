defmodule ProtoTest do
  def test() do
    binary =
      "
08 06 32 7D 0A 01 33 10 01 18 01 22 16 0A 0C 61
40 64 6F 6D 61 69 6E 2E 63 6F 6D 12 06 61 61 61 
61 61 31 2A 16 0A 0C 62 40 64 6F 6D 61 69 6E 2E 
63 6F 6D 12 06 62 62 62 62 62 31 38 DD 8C F9 AB
A6 33 42 31 7B 22 74 65 78 74 22 3A 22 48 65 6C
6C 6F 20 66 72 6F 6D 20 42 49 4D 49 50 20 F0 9F
91 8B 22 2C 22 61 74 74 61 63 68 6D 65 6E 74 73
22 3A 5B 5D 7D 4A 04 6E 6F 6E 65 60 03 72 02 08
01
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