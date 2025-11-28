```Message data

request = %Bimip.Message{
  id: "4",
  from: %Bimip.Identity{
    eid: "a@domain.com"
  },
  to: %Bimip.Identity{
    eid: "b@domain.com"
  },
  timestamp: System.system_time(:millisecond),
  payload: Jason.encode!(%{
    text: "Hello from BIMIP 👋",
    attachments: []
  }),
  encryption_type: "none",
  encrypted: "",
  signature: "",
  signal_type: 1,
}

ack_message = %Bimip.MessageScheme{
  route: 6,
  payload: {:message, request}
}

binary_ack = Bimip.MessageScheme.encode(ack_message)
hex_ack = Base.encode16(binary_ack, case: :upper)





```

Note sending message 
only to is need.


