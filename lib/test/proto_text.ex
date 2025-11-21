defmodule ProtoTest do
  def test() do
    binary =
      "
08 07 3A 4E 0A 01 31 10 21 18 16 20 01 28 A7 9F
FF B7 AA 33 32 16 0A 0C 61 40 64 6F 6D 61 69 6E
2E 63 6F 6D 12 06 61 61 61 61 61 31 3A 16 0A 0C
62 40 64 6F 6D 61 69 6E 2E 63 6F 6D 12 06 62 62
62 62 62 31 40 02 48 01 62 06 08 01 10 01 18 01
68 02
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
