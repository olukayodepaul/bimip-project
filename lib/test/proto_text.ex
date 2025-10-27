defmodule ProtoTest do
  def test() do
    binary =
      "
08 03 1A 24 0A 01 31 12 16 0A 0C 61 40 64 6F 6D
61 69 6E 2E 63 6F 6D 12 06 61 61 61 61 61 31 18
02 20 CE DD DF AB A2 33 


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