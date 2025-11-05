### **Sender Message Strategy (A → B)**

**1. SEND message**

- A user (sender) initiates a message.
- The client generates the message payload, usually including:

  - `id` (unique message ID)
  - `timestamp`
  - `from` (sender info)
  - `to` (receiver info)
  - `payload` (content)

- **Sender’s client sends the message to the server.**

> Note: At this point, message is **in-flight**, not yet acknowledged or persisted.

---

**2. Save on a queue for A and B**

- Server **persists the message in the log/queue** for both sender (A) and receiver (B).
- Two queues can exist:

  - **Sender queue (A)**: for tracking messages sent and pending ACK.
  - **Receiver queue (B)**: for delivery.

- Optional: Store a **user offset** per user in each queue for ordering.

> Rationale: Ensures message can be **retried, acknowledged, or merged** later if needed.

---

**3. Fetch other device pending data and send to A**

- If sender has **multiple devices**, there may be **pending messages for other devices** of A.
- Server retrieves any pending messages for other devices (or pending ACKs) and **pushes them to this device**.

> This keeps all devices in sync — think of WhatsApp’s multi-device approach.

---

**4. Send ACK of newly sent message to A**

- After message is persisted on the server, **send an acknowledgment to the sender**.
- This ACK usually contains:

  - `message_id`
  - `server_offset` (global log offset)
  - Optional: `status` (delivered/pending)

- Sender can now **mark the message as sent** in its local UI.

---

**5. Sender receives pending data of other device → send offset dispose to A**

- Once sender receives **pending messages from other devices**, it **updates its offset** to reflect that those messages have been **received/processed**.
- This is usually called **offset disposal** or **offset commit**.
- Ensures **no duplicate messages** on fetch and maintains **per-device ordering**.

---

✅ This covers the **sender’s full messaging strategy**.

If you want, we can **draw a visual flow** showing:

- Client A → Server → Queue for A & B → ACK → Multi-device sync → Offset disposal

It will make the strategy extremely clear.

Do you want me to create that diagram?

```

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

```

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
    connection_resource_id: "bbbbb1"
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
