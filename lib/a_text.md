//testing login stages testing ping pong
message PingPong {
Identity from = 1; // Sender's identity (user or device)
Identity to = 2; // Optional: target identity (used if resource = OTHERS)
int32 resource = 3; // 1=SAME (server ping), 2=OTHERS (user-to-user ping)
int32 type = 4; // 1=PING, 2=PONG
int64 ping_time = 5; // Unix UTC timestamp (ms)
int64 pong_time = 6; // Unix UTC timestamp (ms)
}

logout = %Bimip.PingPong {
to: %Bimip.Identity{
eid: "a@domain.com",
connection_resource_id: "aaaa1",
},

from: %Bimip.Identity{
eid: "a@domain.com",
connection_resource_id: "aaaaa1",
},

resource: 1,
type: 2,
ping_time: System.system_time(:millisecond)
}
is_logout = %Bimip.MessageScheme{
route: 3,
payload: {:ping_pong, logout}
}

binary = Bimip.MessageScheme.encode(is_logout)
hex = Base.encode16(binary, case: :upper)

08031A3B0A160A0C6140646F6D61696E2E636F6D120661616161613112160A0C6240646F6D61696E2E636F6D12066262626262311801200128BC8DE99D9C33

%Bimip.MessageScheme{
route: 3,
payload: {:ping_pong,
%Bimip.PingPong{
from: %Bimip.Identity{
eid: "a@domain.com",
connection_resource_id: "aaaaa1",
**unknown_fields**: []
},
to: %Bimip.Identity{
eid: "a@domain.com",
connection_resource_id: "aaaaa1",
**unknown_fields**: []
},
resource: 1,
type: 2,
ping_time: 1759925388988,
pong_time: 1759925496321,
**unknown_fields**: []
}},
**unknown_fields**: []
}
