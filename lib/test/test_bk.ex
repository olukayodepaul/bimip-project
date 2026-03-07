defmodule ProtoTest do
  def test() do
    binary =
      "
08 02 12 1B 0A 0E 0A 0C 61 40 64 6F 6D 61 69 6E
2E 63 6F 6D 10 01 20 02 28 80 BD B6 9D CC 33

      "
      |> String.split
      |> Enum.map(&String.to_integer(&1, 16))
      |> :binary.list_to_bin

    # Decode with MessageScheme|>
    message = Bimip.MessageScheme.decode(binary)
    IO.inspect(message, label: "")

  end
end
#  ProtoTest.test()
