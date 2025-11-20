




```Resume Data
ack_signal = %Bimip.Signal{
  status: 7,
  timestamp: System.system_time(:second),
  to: %Bimip.Identity{
    eid: "b@domain.com",
    connection_resource_id: ""
  },
  from: %Bimip.Identity{
    eid: "a@domain.com",
    connection_resource_id: "aaaaa2"
  },
  type: 1
}

ack_message = %Bimip.MessageScheme{
  route: 7,               # route for signaling/ack messages
  payload: {:signal, ack_signal}
}

binary_ack = Bimip.MessageScheme.encode(ack_message)
hex_ack = Base.encode16(binary_ack, case: :upper)

08073A3A200728D991F6C80632160A0C6140646F6D61696E2E636F6D12066161616161313A160A0C6240646F6D61696E2E636F6D12066262626262314001

```

```

ack_signal = %Bimip.Signal{
  id: "1",
  signal_offset: 1,
  user_offset: 1,
  status: 7,
  timestamp: System.system_time(:second),
  from: %Bimip.Identity{
    eid: "b@domain.com",
    connection_resource_id: "bbbbb1"
  },
  to: %Bimip.Identity{
    eid: "a@domain.com",
    connection_resource_id: "aaaaa1"
  },
  type: 1,               # 1 = REQUEST (signal sent to server)
  signal_type: 3,        # 3 = RECEIVER (acknowledgment from receiver)
  signal_offset_state: true,
  signal_ack_state: %Bimip.SignalAckState{
    received: true        # receiver confirms receipt
  }
}

ack_message = %Bimip.MessageScheme{
  route: 7,               # route for signaling/ack messages
  payload: {:signal, ack_signal}
}

binary_ack = Bimip.MessageScheme.encode(ack_message)
hex_ack = Base.encode16(binary_ack, case: :upper)


```



08 07 3A 4C 0A 01 31 10 01 18 01 20 01 28 EB 97
84 FF A9 33 32 16 0A 0C 61 40 64 6F 6D 61 69 6E
2E 63 6F 6D 12 06 61 61 61 61 61 31 3A 16 0A 0C
62 40 64 6F 6D 61 69 6E 2E 63 6F 6D 12 06 62 62
62 62 62 31 40 02 48 01 52 00 58 01 62 02 08 01


08 06 32 7F 0A 01 31 10 01 18 01 22 16 0A 0C 61
40 64 6F 6D 61 69 6E 2E 63 6F 6D 12 06 61 61 61
61 61 32 2A 16 0A 0C 62 40 64 6F 6D 61 69 6E 2E
63 6F 6D 12 06 62 62 62 62 62 31 38 C1 BE FB FE
A9 33 42 31 7B 22 74 65 78 74 22 3A 22 48 65 6C
6C 6F 20 66 72 6F 6D 20 42 49 4D 49 50 20 F0 9F
91 8B 22 2C 22 61 74 74 61 63 68 6D 65 6E 74 73
22 3A 5B 5D 7D 4A 04 6E 6F 6E 65 60 02 72 02 08
01 78 02


08 06 32 7F 0A 01 31 10 01 18 01 22 16 0A 0C 61
40 64 6F 6D 61 69 6E 2E 63 6F 6D 12 06 61 61 61
61 61 31 2A 16 0A 0C 62 40 64 6F 6D 61 69 6E 2E
63 6F 6D 12 06 62 62 62 62 62 31 38 C1 BE FB FE
A9 33 42 31 7B 22 74 65 78 74 22 3A 22 48 65 6C
6C 6F 20 66 72 6F 6D 20 42 49 4D 49 50 20 F0 9F
91 8B 22 2C 22 61 74 74 61 63 68 6D 65 6E 74 73
22 3A 5B 5D 7D 4A 04 6E 6F 6E 65 60 03 72 02 08
01 78 02
