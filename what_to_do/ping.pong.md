```
message PingPong {
    string id = 1;                 // Unique message or request ID (UUID or sequence)
    Identity to = 2;               // Target identity (usually the client's own Identity)
    int32 type = 3;                // 1 = PING, 2 = PONG, 3 = ERROR
    int64 timestamp = 4;           // Unix UTC timestamp in milliseconds
    string details = 5;            // Optional: used only when type = 3 (ERROR)
}


request = %Bimip.PingPong{
  id: "1",
  to: %Bimip.Identity{
    eid: "a@domain.com",
    connection_resource_id: "aaaaa1"
  },
  type: 1,
  timestamp: System.system_time(:second)
}

msg_request = %Bimip.MessageScheme{
  route: 3,
  payload: {:ping_pong, request}
}

binary = Bimip.MessageScheme.encode(msg_request)
hex    = Base.encode16(binary, case: :upper)


```
