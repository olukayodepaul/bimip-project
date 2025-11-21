




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
  to: %Bimip.Identity{
    eid: "b@domain.com",
    connection_resource_id: "bbbbb1"
  },
  from: %Bimip.Identity{
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



````

What you need in your resume / signal handler

Detect status == 1.

Instead of fetching messages (like RESUME/pull), you:

Call your ACK/commit function in BimipLog (or Injection) to mark the message as acknowledged.

Move the offset forward.

Optionally, send a delivery notification to other devices or the sender.

Keep track of signal_ack_state per device so that the client knows the message was acknowledged.

```