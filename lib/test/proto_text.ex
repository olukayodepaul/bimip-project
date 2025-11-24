defmodule ProtoTest do
  def test() do
    binary =
      "
08 07 3A 4C 0A 01 31 10 01 18 01 20 01 28 92 B6
FD 93 AB 33 32 16 0A 0C 62 40 64 6F 6D 61 69 6E
2E 63 6F 6D 12 06 62 62 62 62 62 31 3A 16 0A 0C
62 40 64 6F 6D 61 69 6E 2E 63 6F 6D 12 06 62 62
62 62 62 32 40 02 48 02 62 04 08 01 10 01 68 02

      "
      |> String.split
      |> Enum.map(&String.to_integer(&1, 16))
      |> :binary.list_to_bin

    # Decode with MessageScheme|>
    message = Bimip.MessageScheme.decode(binary)
    IO.inspect(message, label: "")

  end
end


# JWT.generate_tokens(%{device_id: "bbbbb1", eid: "b@domain.com", user_id: "1"})
# Here’s the cleaned-up version with all offsets (`00000000:`) and right-side ASCII removed, keeping only the center data:
