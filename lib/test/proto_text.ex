defmodule ProtoTest do
  def test() do
    binary =
      "
      08 0B 5A 4C 08 64 10 03 1A 3F 46 69 65 6C 64 20
      27 70 6F 6E 67 5F 74 69 6D 65 27 20 E2 86 92 20 
      49 6E 76 61 6C 69 64 20 74 69 6D 65 73 74 61 6D
      70 73 3A 20 70 6F 6E 67 5F 74 69 6D 65 20 3C 20
      70 69 6E 67 5F 74 69 6D 65 20 8E D0 C2 A1 9C 33
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