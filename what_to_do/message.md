```Message data

request = %Bimip.Message{
  id: "4637829384765473892",
  from: %Bimip.Identity{
    eid: "a@domain.com",
    connection_resource_id: "aaaaa1"
  },
  to: %Bimip.Identity{
    eid: "b@domain.com",
    connection_resource_id: "bbbbb1"
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