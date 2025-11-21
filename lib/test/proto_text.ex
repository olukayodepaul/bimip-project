defmodule ProtoTest do
  def test() do
    binary =
      "
08 07 3A 5C 0A 13 34 36 33 37 38 32 39 33 38 34
37 36 35 34 37 33 38 39 32 10 21 18 21 20 01 28
EB C8 C4 B3 AA 33 32 16 0A 0C 61 40 64 6F 6D 61
69 6E 2E 63 6F 6D 12 06 61 61 61 61 61 31 3A 16
0A 0C 62 40 64 6F 6D 61 69 6E 2E 63 6F 6D 12 06
62 62 62 62 62 31 40 02 48 01 62 02 08 01 68 02

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
