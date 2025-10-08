message Logout {
Identity to = 1; // The user/device performing logout
int32 type = 2; // 1 = REQUEST, 2 = RESPONSE
int32 status = 3; // 1 = DISCONNECT, 2 = FAIL, 3 = SUCCESS, 4 = PENDING
int64 timestamp = 4; // Unix UTC timestamp (ms) of the action
}

logout = %Bimip.Logout {
to: %Bimip.Identity{
eid: "a@domain.com",
connection_resource_id: "aaaaa1",
},
type: 1,
status: 4,
timestamp: System.system_time(:millisecond)
}
is_logout = %Bimip.MessageScheme{
route: 10,
payload: {:logout, logout}
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
