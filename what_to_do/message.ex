


// ---------------- Message ----------------
// Represents a chat or notification message between users.
message Message {
  string id = 1;                    // client/queue-generated message ID
  string signal_id = 2;             // server-assigned global ID
  Identity from = 3;                // sender
  Identity to = 4;                  // recipient
  int32 type = 5;                   // 1=Chat | 2=PushNotification
  int64 timestamp = 6;              // epoch milliseconds
  bytes payload = 7;                // JSON { ... }
  string encryption_type = 8;       // "none", "AES256", etc.
  string encrypted = 9;             // base64 encrypted content
  string signature = 10;            // base64 signature for integrity
  int64 status = 11;                // 1=SENT, 2=DELIVERED, 3=READ, 4=FORWARDED, 5=PLAYED, 6=TYPING, 7=RECORDING, 8=PAUSED, 9=CANCELLED, 10=RESUME, 11=CALLING, 12=DECLINE
}



---

Would you like me to show how to implement **step 4** — i.e., how each `bimipSignal` instance should suppress all awareness broadcasts once visibility is disabled?

```
# -------------------------------
# ✅ Example Message Test Payload (Client → Server)
# -------------------------------
request = %Bimip.Message{
  id: "1",
  signal_offset: "5",  # server-assigned global offset
  user_offset: "0",    # per-user offset (A's own queue offset)
  from: %Bimip.Identity{
    eid: "a@domain.com",
    connection_resource_id: "aaaaa2"
  },
  to: %Bimip.Identity{
    eid: "b@domain.com",
    connection_resource_id: "bbbbb2"
  },
  type: 1,
  timestamp: System.system_time(:millisecond),
  payload: Jason.encode!(%{
    text: "Hello from BIMIP 👋",
    attachments: []
  }),
  encryption_type: "none",
  encrypted: "",
  signature: "",
  status: 1
}

msg_scheme = %Bimip.MessageScheme{
  route: 6,             # your route ID
  payload: {:message, request}  # tuple for oneof
}

binary = Bimip.MessageScheme.encode(msg_scheme)
hex    = Base.encode16(binary, case: :upper)
IO.inspect(decoded, label: "Decoded Message (Client → Server)")

```
