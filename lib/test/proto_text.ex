defmodule ProtoTests do
  def test() do
    binary =
      "
08 0B 5A 41 08 06 12 36 46 69 65 6C 64 20 27 74
6F 2E 65 69 64 27 20 E2 86 92 20 62 40 64 6F 6D
61 69 6E 2E 63 6F 6D 20 49 6E 76 61 6C 69 64 20
73 75 62 73 63 72 69 62 65 72 20 35 30 30 18 A1
D2 A5 B1 C9 33
      "
      |> String.split
      |> Enum.map(&String.to_integer(&1, 16))
      |> :binary.list_to_bin

    # Decode with MessageScheme|>
    message = Bimip.MessageScheme.decode(binary)
    IO.inspect(message, label: "")

  end
end
 ProtoTests.test()

# JWT.generate_tokens(%{device_id: "bbbbb1", eid: "b@domain.com", user_id: "1"})
# Here’s the cleaned-up version with all offsets (`00000000:`) and right-side ASCII removed, keeping only the center data:
