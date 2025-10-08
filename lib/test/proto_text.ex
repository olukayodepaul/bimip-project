defmodule ProtoTest do
  def test() do
    binary =
      "
08 03 1A 61 0A 16 0A 0C 61 40 64 6F 6D 61 69 6E   
2E 63 6F 6D 12 06 61 61 61 61 61 31 12 16 0A 0C    
61 40 64 6F 6D 61 69 6E 2E 63 6F 6D 12 06 61 61    
61 61 61 31 18 01 20 03 28 FF A1 F3 A6 9C 33 3A  
24 49 6E 76 61 6C 69 64 20 27 72 65 73 6F 75 72  
63 65 27 20 76 61 6C 75 65 20 28 6D 75 73 74 20 
62 65 20 31 29    


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