# 🟢 Awareness Stanza Documentation

## Overview

The **Awareness stanza** communicates real-time user or system states such as **presence**, **activity**, or **temporary conditions**.
It serves as a lightweight, _fire-and-forget_ alternative to traditional **XMPP presence stanzas**, optimized for:

- **Low latency**
- **Binary transmission**
- **TTL-based expiration**

---

## 🧭 Awareness Mapping

| Category               | Description                                                                 | Status Code | Meaning              |
| ---------------------- | --------------------------------------------------------------------------- | ----------- | -------------------- |
| **User Device State**  | Core connection or session state                                            | `1`         | ONLINE               |
|                        |                                                                             | `2`         | OFFLINE              |
| **User Intent Status** | User’s intentional state for notifications (does _not_ affect reachability) | `3`         | AWAY                 |
|                        |                                                                             | `4`         | BUSY                 |
|                        |                                                                             | `5`         | DO NOT DISTURB (DND) |
| **System Awareness**   | Temporary activity or context                                               | `6`         | TYPING               |
|                        |                                                                             | `7`         | RECORDING            |
|                        |                                                                             | `8`         | RESUME               |

> 💡 _User Intent Status_ affects only **fan-out and notification behaviors**, not actual message routing.

---

## 📍 Location Sharing Policy

| Policy | Description                                              |
| ------ | -------------------------------------------------------- |
| `1`    | **ENABLED** — user shares real-time location coordinates |
| `2`    | **DISABLED** — user hides location coordinates           |

---

## ⚙️ Behavioral Characteristics

- **Fire-and-forget** — no acknowledgment or response required.
- **Transient** — each stanza has a limited lifespan controlled by its `ttl`.
- **Auto-expiry** — servers and clients must discard awareness after `(timestamp + ttl)`.
- **Delay protection** — servers verify TTL before broadcasting to prevent stale updates.
- **Implicit termination** — no `START/STOP` signals; TTL expiration ends the lifecycle automatically.
- **Optimized for** real-time systems, mobile environments, and edge networks.

---

## 🔄 Lifecycle Example

| Action                | Status     | TTL (seconds) | Description                                      |
| --------------------- | ---------- | ------------- | ------------------------------------------------ |
| User starts typing    | `status=6` | `5`           | Client sends "TYPING" awareness                  |
| User continues typing | `status=6` | `5`           | Client refreshes awareness periodically          |
| User stops typing     | —          | —             | No more updates; awareness expires automatically |

---

## 🧮 TTL Handling

Awareness uses **UNIX timestamps (in seconds)** for cross-timezone consistency.

```elixir
# Current UNIX time in seconds
timestamp = System.system_time(:second)

# TTL in seconds (example: 5s)
ttl = 5

# Expiry check
expired? = (System.system_time(:second) - timestamp) > ttl
```

✅ **UNIX time** is consistent globally — it represents the same absolute point in time everywhere, regardless of timezone or country.

---

## 🧠 Summary

The Awareness model unifies presence, intent, and activity signals into one simplified structure —
reducing protocol complexity while improving consistency and efficiency across distributed networks.

| Feature              | Benefit                            |
| -------------------- | ---------------------------------- |
| Single stanza type   | Simplifies protocol handling       |
| TTL-driven lifecycle | Automatic expiry, no extra cleanup |
| Fire-and-forget      | Minimal network chatter            |
| Binary-optimized     | Low latency & bandwidth usage      |
| Global timestamping  | Timezone-agnostic validity         |

---

Would you like me to include a **JSON schema example** (e.g., how the stanza looks over WebSocket or XMPP-like transport)?
That would make this doc even more complete for developers integrating the protocol.

| Category               | Status        | Behavior                                                                                | Persistence | Fan-Out                   |
| ---------------------- | ------------- | --------------------------------------------------------------------------------------- | ----------- | ------------------------- |
| **User Device State**  | `1=ONLINE`    | Send directly to user; also fan-out pending **offline messages** to sender              | ❌          | ✅ (chat + notifications) |
|                        | `2=OFFLINE`   | Send directly to user (notify others)                                                   | ❌          | ❌ (no persistence)       |
| **User Intent Status** | `3=AWAY`      | Send directly to receiver                                                               | ❌          | ❌                        |
|                        | `4=BUSY`      | Send directly to receiver                                                               | ❌          | ❌                        |
|                        | `5=DND`       | Send directly to receiver                                                               | ❌          | ❌                        |
| **System Awareness**   | `6=TYPING`    | Send directly to receiver (typing indicator)                                            | ❌          | ❌                        |
|                        | `7=RECORDING` | Send directly to receiver (voice indicator)                                             | ❌          | ❌                        |
|                        | `8=RESUME`    | Send directly to receiver; fan-out all **offline chat messages only** (no notification) | ❌          | ✅ (messages only)        |

```proto

message Awareness {
  Identity from = 1;
  Identity to = 2;
  int32 type = 3;
  int32 status = 4;
  int32 location_sharing = 5;
  double latitude = 6;
  double longitude = 7;
  int32 ttl = 8;
  string details = 9;
  int64 timestamp = 10;
  }

```

### To do

1. User Device State → status: 1=ONLINE, 2=OFFLINE
2. UserIntentStatus → status: 3=AWAY, 4=BUSY, 5=DND
3. System Awareness → status: 6=TYPING, 7=RECORDING, 8=RESUME

4. User Device State → status: 1=ONLINE, 2=OFFLINE

   - 2 = OFFLINE -> send to user directly without persisting (:offline)
   - 1 = ONLINE -> send to user without persisting and fan out pending offline
     notification and chat message to the sender if there is

5. UserIntentStatus → status: 3=AWAY, 4=BUSY, 5=DND
   3 = AWAY -> send directly to intended receiver without persisting
   4 = BUSY -> send directly to intended receiver without persisting
   5 = DND -> -> send directly to intended receiver without persisting

6. System Awareness → status: 6=TYPING, 7=RECORDING, 8=RESUME
   8 = RESUME -> send to intended receiver and fan out all offline chat message only without notification to the sender
   6=TYPING, 7=RECORDING, -> send to intended receiver without persisting

### Testing Sample

```proto
message Awareness {
  Identity from = 1;
  Identity to = 2;
  int32 type = 3;
  int32 status = 4;
  int32 location_sharing = 5;
  double latitude = 6;
  double longitude = 7;
  int32 ttl = 8;
  string details = 9;
  int64 timestamp = 10;
  }

```

```
BimipLog.write(user, partition_id, from, to, payload)
BimipLog.fetch(user, device_id, partition_id, limit)

```

| Parameter      | Type                       | Description                                                                                                              |
| -------------- | -------------------------- | ------------------------------------------------------------------------------------------------------------------------ |
| `user`         | `String.t()`               | The unique identifier of the log owner (e.g., `"a@domain.com"`). Each user has their own isolated log directory.         |
| `partition_id` | `integer()`                | Numeric partition identifier for the user’s log (e.g., `1`). Each partition represents a separate file stream (segment). |
| `from`         | `String.t()`               | The sender identifier (e.g., `"alice"`). Used for metadata and correlation in delivery fan-out.                          |
| `to`           | `String.t()`               | The receiver identifier (e.g., `"bob"`). Determines routing and awareness linkage.                                       |
| `payload`      | `binary()` or `String.t()` | The actual message data stored in the log. Serialized and length-prefixed for safe binary storage.                       |

| Arg              | Type        | Meaning                                                              |
| ---------------- | ----------- | -------------------------------------------------------------------- |
| **user**         | `string()`  | The log owner (same as in `write/5`).                                |
| **device_id**    | `string()`  | Unique ID of the device reading messages (used for tracking offset). |
| **partition_id** | `integer()` | Which partition to read from (same one used in `write/5`).           |
| **limit**        | `integer()` | How many messages to fetch at once (batch size).                     |

```
request = %Bimip.Awareness{
  id: "1",
  from: %Bimip.Identity{
    eid: "a@domain.com",
    connection_resource_id: "aaaaa1"
  },
  to: %Bimip.Identity{
    eid: "b@domain.com",
    connection_resource_id: "bbbbb1"
  },
  type: 1,
  status: 1,
  location_sharing: 2,
  ttl: 5,
  timestamp: System.system_time(:second)
}

msg_request = %Bimip.MessageScheme{
  route: 2,
  payload: {:awareness, request}
}

binary = Bimip.MessageScheme.encode(msg_request)
hex    = Base.encode16(binary, case: :upper)

BimipLog.write("a@domain.com", 1, "a@domain.com", "b@domain.com", hex)

BimipLog.fetch("a@domain.com", "aaaaa1", 1, 2)

0802123E0A160A0C6140646F6D61696E2E636F6D120661616161613112160A0C6240646F6D61696E2E636F6D12066262626262311801200228024005509ECDF7C706


typing
0802123E0A160A0C6140646F6D61696E2E636F6D120661616161613112160A0C6240646F6D61696E2E636F6D1206626262626231180120062802400550CF8EF8C706


BimipLog.write("a@domain.com", 1, "alice", "bob", "payload1")
BimipLog.fetch("a@domain.com", 1, "alice", "bob", "payload1")

BimipLog.fetch("a@domain.com", "aaaaa1", 1, 2)

BimipLog.write("a@domain.com", 1, "a@domain.com", "b@domain.com", hex)


BimipLog.write("a@domain.com", 1, "a@domain.com", "b@domain.com", 0802123E0A160A0C6140646F6D61696E2E636F6D120661616161613112160A0C6240646F6D61696E2E636F6D1206626262626231180120062802400550CF8EF8C706)


# GenServer.cast(self(), {:log_user_message, 1, "a@domain.com", "b@domain.com", "hex_payload"})
```

msg_request = %Bimip.MessageScheme{
route: 10,
payload: {:body, [
list of itemis
]}
}

request = %Bimip.Awareness{
from: %Bimip.Identity{
eid: "a@domain.com",
connection_resource_id: "aaaaa1"
},
to: %Bimip.Identity{
eid: "b@domain.com",
connection_resource_id: "bbbbb1"
},
type: 1,
status: 6,
location_sharing: 2,
ttl: 5,
timestamp: System.system_time(:second)
}

msg_request = %Bimip.MessageScheme{
route: 10,
payload: {:body, [
request, request
]}
}

body route = 20
message Body {
array body = 1;
}

%Bimip.MessageScheme{
route: 10,
payload: {:body, %Bimip.Body{
route: 1001,
awareness_list: [...]
...
}}
}

%Bimip.MessageScheme{
route: 10,
payload: {:body, %Bimip.Body{
route: 1001,
awareness_list: [...]
...
}}
}

awareness_struct = %Bimip.Awareness{
from: %Bimip.Identity{eid: "alice"},
to: %Bimip.Identity{eid: "bob"},
status: 1,
ttl: 5,
timestamp: 1_761_488_000_000
}

message = %Bimip.MessageScheme{
route: 10,
payload: {:body, %Bimip.Body{
route: 1001,
awareness_list: [awareness_struct],
timestamp: awareness_struct.timestamp
}}
}
