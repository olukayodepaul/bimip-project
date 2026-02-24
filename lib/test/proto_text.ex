defmodule ProtoTest do
  def test() do
    binary =
      "
 08 07 3A 1B 0A 0E 0A 0C 61 40 64 6F 6D 61 69 6E
 2E 63 6F 6D 10 02 18 01 20 A7 FB 9F E9 C8 33
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
