```Message data

request = %Bimip.Message{
  id: "5",
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

08073A1B2001288ECBABC9063A0D0A0B40646F6D61696E2E636F6D40017001


```

Note sending message 
only to is need.


