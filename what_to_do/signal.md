




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

----
**ACK AND SENDER for pulling message ack stat**
```
ack_signal = %Bimip.Signal{
  id: "1",
  signal_offset: 1,
  user_offset: 1,
  status: 1,
  timestamp: System.system_time(:second),
  to: %Bimip.Identity{
    eid: "b@domain.com",
    connection_resource_id: "bbbbb1"
  },
  from: %Bimip.Identity{
    eid: "a@domain.com",
    connection_resource_id: "aaaaa1"
  },
  type: 1,               # 1 = REQUEST (signal sent to server)
  signal_type: 3,        # 1 = SENDER (acknowledgment from receiver)
  signal_lifecycle_state: "read"
}

ack_message = %Bimip.MessageScheme{
  route: 7,               # route for signaling/ack messages
  payload: {:signal, ack_signal}
}

binary_ack = Bimip.MessageScheme.encode(ack_message)
hex_ack = Base.encode16(binary_ack, case: :upper)

----