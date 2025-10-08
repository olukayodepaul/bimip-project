```
message PingPong {
  Identity from = 1;              // Sender's identity (user or device)
  Identity to = 2;                // Target identity (used if resource = OTHERS)
  int32 resource = 3;             // 1=SAME (server ping), 2=OTHERS (user-to-user ping)
  int32 type = 4;                 // 1=PING, 2=PONG, 3=ERROR
  int64 ping_time = 5;            // Unix UTC timestamp (ms)
  int64 pong_time = 6;            // Unix UTC timestamp (ms)
  string error_reason = 7;        // Optional: only set when type = 3 (ERROR)
}

logout = %Bimip.PingPong {
to: %Bimip.Identity{
eid: "a@domain.com",
connection_resource_id: "aaaaa1",
},
from: %Bimip.Identity{
eid: "a@domain.com",
connection_resource_id: "aaaaa1",
},
resource: 1,
type: 1,
ping_time: System.system_time(:millisecond)
}
is_logout = %Bimip.MessageScheme{
route: 3,
payload: {:ping_pong, logout}
}

binary = Bimip.MessageScheme.encode(is_logout)
hex = Base.encode16(binary, case: :upper)
```
