what to do

Awareness

1. User Device State → status: 1=ONLINE, 2=OFFLINE
2. UserIntentStatus → status: 3=AWAY, 4=BUSY, 5=DND
3. System Awareness → status: 6=TYPING, 7=RECORDING, 8=RESUME

4. User Device State → status: 1=ONLINE, 2=OFFLINE
   2 = OFFLINE -> send to user directly
   1 = ONLINE -> send to user and fan out pending offline notification(ack: false) and chat message to sender from queueing system

5. UserIntentStatus → status: 3=AWAY, 4=BUSY, 5=DND
   3 = AWAY -> send directly to user
   4 = BUSY -> send directly to user
   5 = DND -> -> send directly to user

6. System Awareness → status: 6=TYPING, 7=RECORDING, 8=RESUME
   8 = RESUME -> send to user and fan out all offline message using last incremental id monotonic
   6=TYPING, 7=RECORDING, -> send to user and fire and foget

Sure! Based on everything we’ve discussed today, here’s a **summary table of the key concepts, statuses, and queue behaviors** for your Awareness + Queue system:

| Layer / Table                    | Field / Status        | Value / Description                    | Behavior                                                              |
| -------------------------------- | --------------------- | -------------------------------------- | --------------------------------------------------------------------- |
| **BimipQueue (per user)**        | `offset`              | Monotonic numeric ID per message       | Used to track message order and last fetched position                 |
|                                  | `partition_id`        | e.g., `chat`, `notification`           | Identifies which type of queue the message belongs to                 |
|                                  | `from`                | Sender user ID                         |                                                                       |
|                                  | `to`                  | Receiver user ID                       |                                                                       |
|                                  | `payload`             | Actual message or notification content |                                                                       |
|                                  | `timestamp`           | Unix milliseconds timestamp            |                                                                       |
|                                  | `acknowledged`        | `true/false`                           | Indicates whether the message was delivered/processed                 |
| **BimipQueueIndex (per device)** | `next_offset`         | Number tracking next message to fetch  | Ensures each device fetches messages **idempotently**                 |
|                                  | `partition_id`        | e.g., `chat`, `notification`           |                                                                       |
|                                  | `from`                | Sender user ID                         |                                                                       |
|                                  | `to`                  | Receiver user ID                       |                                                                       |
| **User Device State**            | `status`              | 1 = ONLINE, 2 = OFFLINE                | ONLINE → fan-out pending messages; OFFLINE → direct send only         |
| **User Intent Status**           | `status`              | 3 = AWAY, 4 = BUSY, 5 = DND            | Direct send only                                                      |
| **System Awareness**             | `status`              | 6 = TYPING, 7 = RECORDING, 8 = RESUME  | TYPING/RECORDING → fire-and-forget; RESUME → fan-out pending messages |
| **Folder structure**             | Prefix-based sharding | `data/bimip/<prefix>/<user>/`          | Distributes users evenly across 256 folders                           |
| **File per user**                | Queue file            | `bimip_queue_<user>.dat`               | Stores messages as Base64-encoded lines                               |
|                                  | Index file            | `bimip_queue_index_<user>.dat`         | Tracks next_offset per (partition_id, from, to)                       |

---

💡 **Summary of Flow**

1. **User comes online → device state = ONLINE** → fan-out pending offline messages to UI contact list.
2. **User opens chat → system awareness = RESUME** → fetch pending messages for that contact only.
3. **Realtime events (TYPING/RECORDING)** → fire-and-forget to update UI.
4. **Offline messages** are stored in `bimip_queue` with `ack = false` until delivered.

This table can serve as a **reference for implementation, testing, and future scaling**.

---

If you want, I can **draw a visual diagram today** showing **all these tables and the flow between them**, which will complement this table.

Do you want me to do that?
