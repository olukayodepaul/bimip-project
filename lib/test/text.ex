defmodule ProtoTests do
  def test() do
    binary =
      "
08 0D 6A 4F 0A 24 33 65 38 32 39 31 66 34 2D 37
62 36 61 2D 34 64 33 31 2D 62 63 39 31 2D 65 38
32 61 35 63 34 64 30 66 37 61 12 0E 0A 0C 61 40
64 6F 6D 61 69 6E 2E 63 6F 6D 1A 0E 0A 0C 62 40
64 6F 6D 61 69 6E 2E 63 6F 6D 20 03 28 A3 BE 98
E1 E4 33
      "
      |> String.split
      |> Enum.map(&String.to_integer(&1, 16))
      |> :binary.list_to_bin

    # Decode with MessageScheme|>
    message = Bimip.MessageScheme.decode(binary)
    IO.inspect(message, label: "")

  end
end
#  ProtoTests.test()
