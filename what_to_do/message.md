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

**6. Adding grace period for offset ack to syn**

- Allow message pull from other device to full ack before another message is full. **This prevent dublicate pulling**
- Reset grace period when ack offset

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
  int64 status = 11;                // 1=SENT, 2=DELIVERED, 3=READ, 4=FORWARDED, 5=PLAYED, 6=TYPING, 7=RECORDING, 8=PAUSED, 9=CANCELLED, 10=RESUME, 11=CALLING, 12=DECLINE, 13=,
}

```

---

Would you like me to show how to implement **step 4** — i.e., how each `bimipSignal` instance should suppress all awareness broadcasts once visibility is disabled?

Excellent question — this is where chat systems get _really interesting_.

You’ve already implemented a solid **core sender strategy (A → B)**, but now for **A1 ↔ A2** (multi-device synchronization for the _same user_), there are multiple complementary **strategies** you can apply, depending on your design goal:

- **Strong sync consistency** (like iMessage or Signal)
- **Eventual consistency** (like WhatsApp or Telegram Web)
- **Bandwidth and performance optimization**

---

## 🧠 Overview: Multi-Device Message Synchronization Strategies (A1 ↔ A2)

Let’s group them by _purpose_ so it’s easier to reason about.

---

### **1. Mirror Queue Strategy (per-device consumer)**

> Each device (A1, A2, A3...) maintains its own read offset in the same user queue.

#### How it works:

- You maintain **a single log** for user A.
- Each device has a separate offset pointer (`device_id → offset`).
- Messages are fetched independently but from the same source.
- When a message is ACKed by one device, others can still read until they ACK theirs.

#### Benefits:

- Simple design.
- Guaranteed per-device order.
- Can replay or backfill missed messages (offline sync).

#### Use case:

WhatsApp, Telegram — each device consumes messages independently from the same log.

---

### **2. Device Shadow State (mirror state replication)**

> Server maintains a **shadow state** per device that mirrors user’s chat state.

#### How it works:

- When A1 sends or updates a message, the server updates a “device shadow state” for A2.
- On reconnect, A2 simply fetches _delta changes_ from its shadow.
- Once ACKed, the shadow is merged or cleared.

#### Benefits:

- Extremely fast resync after disconnection.
- Efficient for large device lists (e.g., desktop + phone + tablet).

#### Use case:

WhatsApp multi-device implementation post-2021 uses a form of this via sync database snapshots.

---

### **3. Real-Time Fanout (live mirror broadcasting)**

> Server immediately pushes all new events for A1 to A2 (and vice versa).

#### How it works:

- You keep all A’s active devices in a **PubSub group** or **ETS registry list**.
- When one device sends a message or receives an ACK, it’s broadcast to all others.

```elixir
for device_pid <- Registry.lookup(:user_sessions, user_id) do
  send(device_pid, {:mirror_update, message})
end
```

#### Benefits:

- Instant sync across devices (typing indicators, read receipts, live edits).
- Zero polling.

#### Drawback:

- Requires careful state deduplication on client side.

#### Use case:

Signal, iMessage, Facebook Messenger (multi-device sessions).

---

### **4. Delta Sync (incremental state reconciliation)**

> Devices exchange _diffs_ (state deltas) instead of entire histories.

#### How it works:

- Each device maintains a `last_sync_timestamp` or version.
- When A2 reconnects, it asks the server for “all changes since version X”.
- Server computes and sends only diffs: new messages, updates, or deletes.

#### Benefits:

- Saves bandwidth and CPU.
- Good for long-disconnected devices.

#### Use case:

Slack, Discord, and most enterprise messaging tools.

---

### **5. Snapshot and Resume Strategy**

> Periodically checkpoint device message states so recovery is faster.

#### How it works:

- Every N messages or M seconds, store a **snapshot** (offset + message hash state).
- On reconnect, the device requests:

  ```elixir
  {:resume_from_snapshot, snapshot_id}
  ```

- Server compares checksums and sends only missing parts.

#### Benefits:

- Reliable recovery for mobile networks.
- Helps with deduplication or partial corruption.

#### Use case:

Telegram Desktop / Signal Desktop.

---

### **6. Unified Commit Offset (group-based commit)**

> Devices share a _merged commit offset_, ensuring all have caught up before discarding data.

#### How it works:

- Server maintains a map of offsets:

  ```
  A1 → 45
  A2 → 42
  Merged (min offset) = 42
  ```

- Messages older than 42 are safe to delete or skip during resend.

#### Benefit:

- Prevents one slow device from causing duplicates.
- Easy cleanup and retention control.

---

### **7. Delayed ACK / Grace Window (already in your Step 6)**

> Adds a waiting period for ACK propagation before pulling more messages.

#### Use case:

You already have this — and it’s crucial for cross-device race prevention.

---

### **8. Cross-Device Command Replication**

> Send metadata commands (like “delete”, “edit”, “read”) as _replication messages_.

#### How it works:

- A1 marks a message as “read” or “deleted”.
- Instead of local-only, this emits a command to the server:

  ```elixir
  {:sync_command, :read, msg_id}
  ```

- Server replicates this to all other devices’ queues.

#### Benefits:

- Perfect sync for read receipts, emoji reactions, edits, deletions.

#### Use case:

WhatsApp, iMessage, Telegram.

---

### **9. Ephemeral Peer Gossip (optional optimization)**

> Devices talk to each other directly (via WebRTC or LAN) for local sync.

#### How it works:

- On same network or same account, A1 and A2 exchange cached messages directly.
- Server is informed after sync completes.

#### Benefits:

- Instant sync without hitting server.
- Great for local network or P2P design.

#### Drawback:

- Needs encryption and NAT handling.

#### Use case:

Signal (used for encrypted file sync), experimental WhatsApp multi-device local sync.

---

### **10. Conflict Resolution Strategy**

> Defines rules for which device wins when both modify the same message concurrently.

#### Common policies:

- **Last write wins** (timestamp-based)
- **Vector clocks** (Lamport or hybrid logical clock)
- **CRDT (Conflict-free Replicated Data Types)** for advanced merging

#### Example (simple):

```elixir
def resolve_conflict(msg1, msg2) do
  if msg1.timestamp > msg2.timestamp, do: msg1, else: msg2
end
```

#### Use case:

Slack, Signal, WhatsApp (for message updates or “delete for me” cases).

---

## 🧩 Recommended Combined Strategy for Your System

Since your chat system already uses **Mnesia**, **ETS**, and **offset-based logs**, the most natural hybrid would be:

| Layer               | Strategy                              |
| ------------------- | ------------------------------------- |
| Message storage     | Mirror Queue (shared per-user log)    |
| Real-time delivery  | Fanout broadcast (Registry or PubSub) |
| State recovery      | Delta Sync + Snapshot                 |
| Offset tracking     | Unified Commit Offset + Grace Period  |
| Command updates     | Cross-Device Command Replication      |
| Conflict resolution | Last-write or timestamp-based merge   |

This combination gives you:

- Near-instant device sync
- Consistent ordering
- Reliable offline recovery
- Efficient bandwidth use

---

Would you like me to diagram how these strategies interact (with A1, A2, Server, B) — showing the message, ack, and offset flows visually? It would make the multi-device sync logic crystal clear.

```
# -------------------------------
# ✅ Example Message Test Payload (Client → Server)
# -------------------------------

signal_offset: "",  # server-assigned global offset
user_offset: "0",    # per-user offset (A's own queue offset)


request = %Bimip.Message{
  id: "3",
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
  signal_type: 2
}

msg_scheme = %Bimip.MessageScheme{
  route: 6,             # your route ID
  payload: {:message, request}  # tuple for oneof
}

binary = Bimip.MessageScheme.encode(msg_scheme)
hex    = Base.encode16(binary, case: :upper)
IO.inspect(decoded, label: "Decoded Message (Client → Server)")




request = %Bimip.Message{
  id: "3",
  to: %Bimip.Identity{
    eid: "a@domain.com",
    connection_resource_id: "aaaaa1"
  },
  from: %Bimip.Identity{
    eid: "b@domain.com",
    connection_resource_id: "bbbbb1"
  },
  timestamp: System.system_time(:millisecond),
  payload: Jason.encode!(%{
    text: "Hello from BIMIP 👋",
    attachments: []
  }),
  encryption_type: "",
  encrypted: "",
  signature: "",
  signal_type: 2,
}

msg_scheme = %Bimip.MessageScheme{
  route: 6,         # your route ID
  message: request   # just set the optional field directly
}

binary = Bimip.MessageScheme.encode(msg_scheme)
hex    = Base.encode16(binary, case: :upper)
```

---

Full message lifecycle for clarity:
A1 → Server: Send message (offset N).
Server → A1: “Sent” ACK (message persisted and queued).
A1 updates local status to “sent”. ✅
No ACK back to server is needed.
Server → B: Deliver message (offset M for B).
B → Server: “Received” ACK.
Server → A1: “Delivered” notification (B got the message).
B → Server: “Read” notification (optional, if B reads the message).
Server → A1: “Read” notification.
Only B sends ACKs to server for messages it received.
A1 only tracks server ACKs to know the status of its sent messages.
