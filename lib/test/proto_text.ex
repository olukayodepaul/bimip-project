defmodule ProtoTest do
  def test() do
    binary =
      "
08 02 12 68 12 16 0A 0C 61 40 64 6F 6D 61 69 6E
2E 63 6F 6D 12 06 61 61 61 61 61 31 1A 16 0A 0C
61 40 64 6F 6D 61 69 6E 2E 63 6F 6D 12 06 61 61
61 61 61 31 20 03 30 02 52 2B 46 69 65 6C 64 20
27 69 64 27 20 E2 86 92 20 41 77 61 72 65 6E 65
73 73 20 69 64 20 63 61 6E 6E 6F 74 20 62 65 20
65 6D 70 74 79 58 8E E6 91 91 A2 33
   


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