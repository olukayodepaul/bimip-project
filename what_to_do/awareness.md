Got it ✅ — you want **grouped numbering** (e.g., 1.x, 2.x, 3.x, 4.x) that aligns with your logical categories.
Here’s the clean, grouped version 👇

---

### **Awareness Behavior Table (Grouped Version)**

| Group   | Category               |  Code   | Meaning       | Behavior / Flow                                                                                                                                                                                      | Persistence | Fan-Out / Direction          |
| :------ | :--------------------- | :-----: | :------------ | :--------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | :---------- | :--------------------------- |
| **1.x** | **User Device State**  |    1    | **ONLINE**    | Update device state → Master GenServer → Broadcast to all subscribers → Fan out off line queue to sender → Subscribers update local and fanout to device → consider awareness permission(visibility) | ❌          | ✅ (to all subscribers)      |
|         |                        |    2    | **OFFLINE**   | Update device state → Master GenServer → Broadcast to all subscribers → Subscribers update local and fanout to device → consider awareness permission(visibility)                                    | ❌          | ✅ (to all subscribers)      |
| **2.x** | **User Intent Status** |    3    | **AWAY**      | Master GenServer → Broadcast to all subscribers → Subscribers update local to ONLINE without fanout to device                                                                                        | ❌          | ✅ (to all subscribers)      |
|         |                        |   11    | **RESUME**    | Send **RESUME** to self → Fan-out to self all **pending chat messages** for this `{to}`                                                                                                              | ❌          | ✅ (to self only)            |
|         |                        |    4    | **BUSY**      | Master GenServer → Broadcast to all subscribers → Subscribers update local to ONLINE without fanout to device                                                                                        | ❌          | ✅ (to all subscribers)      |
|         |                        |    5    | **DND**       | Master GenServer → Broadcast to all subscribers → Subscribers update local to ONLINE without fanout to device                                                                                        | ❌          | ✅ (to all subscribers)      |
| **3.x** | **System Awareness**   |    6    | **TYPING**    | Master GenServer → Broadcast to Only subscriber communicating with → Subscribers update local to ONLINE and fanout to all device                                                                     | ❌          | 🚀 (to receiver device only) |
|         |                        |    7    | **RECORDING** | Master GenServer → Broadcast to Only subscriber communicating with → Subscribers update local to ONLINE and fanout to all device                                                                     | ❌          | 🚀 (to receiver device only) |
| **4.x** | **Delivery Status**    |    8    | **FORWARDED** | Master GenServer → Broadcast to Only subscriber communicating with → Subscribers update local to ONLINE and fanout to all device                                                                     | ✅/❌       | ❌                           |
|         |                        |    9    | **DELIVERED** | Master GenServer → Broadcast to Only subscriber communicating with → Subscribers update local to ONLINE and fanout to all device                                                                     | ✅          | ❌                           |
|         |                        | 10 - 12 | **READ SEND** | Master GenServer → Broadcast to Only subscriber communicating with → Subscribers update local to ONLINE and fanout to all device                                                                     | ✅          | ❌                           |

---

| Stage | Label / Name             | Symbol Seen in UI           | Meaning                                                              | Scope             |
| :---- | :----------------------- | :-------------------------- | :------------------------------------------------------------------- | :---------------- |
| **1** | **Pending / Sending**    | 🕓 (Clock icon)             | Message is still on the sender’s device — not yet uploaded to server | Local only        |
| **2** | **Sent**                 | ✓ (Single tick)             | Message successfully uploaded to WhatsApp server                     | Sender ↔ Server   |
| **3** | **Delivered**            | ✓✓ (Double tick, gray)      | Message delivered to recipient’s device(s) but not yet read          | Sender ↔ Receiver |
| **4** | **Read**                 | ✓✓ (Double tick, blue)      | Message opened/read by recipient                                     | Sender ↔ Receiver |
| **5** | **Played**               | ▶️✓✓ (Blue for voice notes) | Audio message played or viewed                                       | Sender ↔ Receiver |
| **6** | **Deleted for Everyone** | ❌                          | Message was deleted from both sender and receiver chats              | Sender ↔ Receiver |
| **7** | **Deleted for Me**       | ❌                          | Message deleted locally only                                         | Local only        |
| **8** | **Forwarded**            | 🔁                          | Message marked as forwarded (shows “Forwarded” label)                | Metadata only     |

| **Stage**                      | **From → To**                       | **Purpose**                                          | **Message Content**                                                             | **Server Behavior**                                                     | **Client UI Status**               |
| ------------------------------ | ----------------------------------- | ---------------------------------------------------- | ------------------------------------------------------------------------------- | ----------------------------------------------------------------------- | ---------------------------------- |
| **1️⃣ SEND_REQUEST**            | **Sender → Server**                 | Sender transmits a message with a temporary ID       | `{local_id: "tmp_abc123", to: "b@domain", payload: "Hi"}`                       | Validates, writes to queue (`BimipLog.write/5`), assigns `msg_id = 101` | —                                  |
| **2️⃣ SERVER_ACK (SENT)**       | **Server → Sender**                 | Confirms message stored; provides server-assigned ID | `{ack_type: "SERVER_ACK", local_id: "tmp_abc123", msg_id: 101, status: "SENT"}` | Returns assigned offset (msg_id) to sender                              | ✅ **One gray tick (✓)**           |
| **3️⃣ DELIVER (PUSH)**          | **Server → Receiver**               | Delivers actual message using server msg_id          | `{msg_id: 101, from: "a@domain", payload: "Hi"}`                                | Routes to receiver’s session or stores for offline                      | Receiver receives message          |
| **4️⃣ DELIVER_ACK (DELIVERED)** | **Receiver → Server**               | Confirms receiver device got message                 | `{msg_id: 101, status: "DELIVERED"}`                                            | Marks as delivered; may fan out to sender                               | ✅✅ **Two gray ticks (✓✓)**       |
| **5️⃣ READ_ACK (READ)**         | **Receiver → Server**               | Confirms user opened/read message                    | `{msg_id: 101, status: "READ"}`                                                 | Updates message state; forwards to sender                               | ✅✅ **Two blue ticks (✓✓)**       |
| **6️⃣ OFFLINE_RETRY**           | **Server → Receiver (when online)** | Sends undelivered messages (if receiver was offline) | `{msg_id: 101, payload: "Hi"}`                                                  | Uses queue replay (`fetch` based on `device_offset`)                    | Delivered again; triggers ACK flow |

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


```
