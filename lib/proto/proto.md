protoc \
 --proto_path=./priv/protos \
 --elixir_out=plugins=grpc:./lib/proto \
 ./priv/protos/dartmessage.proto

## Testing UserContactList

```
user_contact = %Dartmessaging.PresenceSu
bscription{
  eid: "user_123",
  device_id: "aaaaa",
  friends: ["friend_1", "friend_2", "friend_3"],
  online: true,
  last_seen: :os.system_time(:millisecond)
}
binary = Dartmessaging.PresenceSubscription.encode(user_contact)
hex = Base.encode16(binary, case: :upper)

```

```

user_contact = %Dartmessaging.PresenceSubscription{
  eid: "user_123",
  device_id: "aaaaa",
  friends: ["friend_1", "friend_2", "friend_3"],
  online: true,
  last_seen: :os.system_time(:second)  # safer for protobuf
}


user_contact = %Dartmessaging.PresenceSubscription{
  eid: "a@domain.com",
  device_id: "aaaaa",
  friends: ["b@domain.com"],
  online: true,
  last_seen: :os.system_time(:millisecond)
}

user_contact = %Dartmessaging.PresenceSubscription{
  eid: "b@domain.com",
  device_id: "bbbbb",
  friends: ["a@domain.com"],
  online: true,
  last_seen: :os.system_time(:millisecond)
}


user_contact = %Dartmessaging.PresenceSubscription{
  eid: "b@domain.com",
  device_id: "bbbbb",
  friends: ["a@domain.com"],
  online: true,
  last_seen: :os.system_time(:millisecond)
}




binary = Dartmessaging.PresenceSubscription.encode(user_contact)
hex = Base.encode16(binary, case: :upper)



signal = %Dartmessaging.PresenceSignal{
  eid: "user_a@domain.com",
  device_id: "device_001",
  last_seen: DateTime.utc_now() |> DateTime.to_unix(),
  status: :ONLINE,
  latitude: 6.5244,
  longitude: 3.3792
}

binary = Dartmessaging.Awareness.encode(user_contact)
hex = Base.encode16(binary, case: :upper)

JWT.generate_tokens(%{device_id: "aaaaa", eid: "a@domain.com", user_id: "1"})
JWT.generate_tokens(%{device_id: "bbbbb", eid: "b@domain.com", user_id: "1"})
```

0A0C6140646F6D61696E2E636F6D120561616161611A0C6240646F6D61696E2E636F6D200128F39BA88F8C33

user_contact = %Dartmessaging.Awareness{
from: "b@domain.com/bbbbb1",
last_seen: DateTime.utc_now() |> DateTime.to_unix(),
status: "ONLINE",
latitude: 6.5244,
longitude: 3.3792
}

binary = Dartmessaging.Awareness.encode(user_contact)
hex = Base.encode16(binary, case: :upper)

# Another instance

user_contact = %Dartmessaging.Awareness{
from: "bob@domain.com/laptop",
last_seen: DateTime.utc_now() |> DateTime.to_unix(),
status: AwarenessStatus.AWAY,
latitude: 51.5074,
longitude: -0.1278
}

```
alias Dartmessaging.Awareness

# Use the fully qualified enum
user_contact = %Awareness{
  from: "a@domain.com/aaaaa1",
  last_seen: DateTime.utc_now() |> DateTime.to_unix(),
  status: :ONLINE,   # enum value as atom
  latitude: 6.5244,
  longitude: 3.3792
}

# Encode to protobuf binary
binary = Dartmessaging.Awareness.encode(user_contact)
hex = Base.encode16(binary, case: :upper)

IO.puts(hex)

```
