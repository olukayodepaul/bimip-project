defmodule ProtoTest do
  def test() do
    binary =
      "
08 06 32 A9 01 0A 13 34 36 33 37 38 32 39 33 38
34 37 36 35 34 37 33 38 39 32 10 29 18 29 22 16
0A 0C 61 40 64 6F 6D 61 69 6E 2E 63 6F 6D 12 06
61 61 61 61 61 31 2A 16 0A 0C 61 40 64 6F 6D 61
69 6E 2E 63 6F 6D 12 06 61 61 61 61 61 32 38 EF
8C F4 DE AA 33 42 31 7B 22 74 65 78 74 22 3A 22
48 65 6C 6C 6F 20 66 72 6F 6D 20 42 49 4D 49 50
20 F0 9F 91 8B 22 2C 22 61 74 74 61 63 68 6D 65
6E 74 73 22 3A 5B 5D 7D 4A 04 6E 6F 6E 65 60 02
6A 02 08 01 70 02 7A 16 0A 0C 61 40 64 6F 6D 61
69 6E 2E 63 6F 6D 12 06 61 61 61 61 61 31
      "
      |> String.split
      |> Enum.map(&String.to_integer(&1, 16))
      |> :binary.list_to_bin

    # Decode with MessageScheme|>
    message = Bimip.MessageScheme.decode(binary)
    IO.inspect(message, label: "")

  end
end

# ProtoTest.test()


# JWT.generate_tokens(%{device_id: "bbbbb1", eid: "b@domain.com", user_id: "1"})





# Here’s the cleaned-up version with all offsets (`00000000:`) and right-side ASCII removed, keeping only the center data:
