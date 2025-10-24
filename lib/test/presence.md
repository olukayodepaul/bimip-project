// ---------------- Awareness ----------------
//
// The Awareness stanza communicates real-time user or system states
// such as presence, activity, or temporary conditions. It serves as a
// lightweight, fire-and-forget alternative to XMPP presence stanzas,
// optimized for low latency, binary transmission, and TTL-based expiration.
//
// ──────────────────────────────────────────────
// Awareness Mapping:
// • User Awareness → status: 1=ONLINE, 2=OFFLINE, 3=AWAY, 4=BUSY, 5=DND
// • System Awareness → status: 6=TYPING, 7=RECORDING
//
// Location Sharing Policy:
// • 1 = ENABLED → user shares real-time location
// • 2 = DISABLED → user hides location coordinates
//
// Behavioral Characteristics:
// • Fire-and-forget — no acknowledgment or response required.
// • Transient — each stanza has a limited lifespan controlled by ttl.
// • Auto-expiry — servers and clients must discard awareness after (timestamp + ttl).
// • Delay protection — servers verify TTL before broadcasting to avoid stale events.
// • No START/STOP actions — TTL expiration implicitly ends the awareness lifecycle.
// • Suitable for real-time systems, mobile devices, and edge networks.
//
// Lifecycle Example:
// → User starts typing: send status=6 (TYPING), ttl=5
// → If user keeps typing: client periodically refreshes stanza
// → If user stops: no further messages; awareness expires naturally
//
// This unified model simplifies the protocol compared to XMPP’s multiple presence
// and activity stanzas, reduces network overhead, and ensures consistency across
// unreliable or high-latency environments.

message Awareness {
Identity from = 1; // Sender's identity (user or device)
Identity to = 2; // Target identity (used if resource = OTHERS)
int32 type = 3; // 1=REQUEST, 2=RESPONSE, 3=ERROR
int32 status = 4; // Awareness state (see mapping above)
int32 location_sharing = 5; // 1=ENABLED, 2=DISABLED
double latitude = 6; // Latitude (if sharing enabled)
double longitude = 7; // Longitude (if sharing enabled)
int32 ttl = 8; // Validity duration in seconds before expiration
string details = 9; // Additional info (optional)
int64 timestamp = 10; // Epoch time in milliseconds (creation time)
}

logout = %Bimip.Awareness {
from: %Bimip.Identity{
eid: "a@domain.com",
connection_resource_id: "aaaaa1",
},

to: %Bimip.Identity{
eid: "b@domain.com",
connection_resource_id: "bbbbb1",
},

type: 1,
status: 3,
location_sharing: 2,
latitude: 1.0,
longitude: 3.0,
ttl: 5,
timestamp: System.system_time(:millisecond)
}

is_logout = %Bimip.MessageScheme{
route: 2,
payload: {:awareness, logout}
}

binary = Bimip.MessageScheme.encode(is_logout)
hex = Base.encode16(binary, case: :upper)

080212510A160A0C6140646F6D61696E2E636F6D120661616161613112160A0C6240646F6D61696E2E636F6D120662626262623118012001280231000000000000F03F390000000000000840400550A5D2F9EB9C33

080212510A160A0C6140646F6D61696E2E636F6D120661616161613112160A0C6240646F6D61696E2E636F6D120662626262623118012006280131000000000000F03F39000000000000084040055086BABEE89C33
