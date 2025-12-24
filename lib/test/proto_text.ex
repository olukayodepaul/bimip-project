defmodule ProtoTest do
  def test() do
    binary =
      "
08 0D 6A 67 0A 0E 0A 0C 61 40 64 6F 6D 61 69 6E
2E 63 6F 6D 12 0E 0A 0C 62 40 64 6F 6D 61 69 6E
2E 63 6F 6D 1A 25 76 63 4E 41 51 63 44 6F 49 49
42 34 54 43 43 41 64 30 43 41 51 41 78 67 67 45
32 4D 49 49 42 4D 67 49 64 64 64 20 02 28 8B D6
DB E0 B4 33 30 C8 01 3A 10 0A 0C 62 40 64 6F 6D
61 69 6E 2E 63 6F 6D 10 01 40 01
      "
      |> String.split
      |> Enum.map(&String.to_integer(&1, 16))
      |> :binary.list_to_bin

    # Decode with MessageScheme|>
    message = Bimip.MessageScheme.decode(binary)
    IO.inspect(message, label: "")

  end
end
 ProtoTest.test()

# JWT.generate_tokens(%{device_id: "bbbbb1", eid: "b@domain.com", user_id: "1"})
# Here’s the cleaned-up version with all offsets (`00000000:`) and right-side ASCII removed, keeping only the center data:
