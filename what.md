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

Perfect! Let’s use concrete data to illustrate **how fetch, next_offset, and ack work together** for multiple devices sharing the same partition.

---

### **Setup**

User: `"paul@id"`
Partition: `"chat_a"`
Sender: `"paul@id"`
Devices: `device_1`, `device_2`

Messages in queue (initially):

| offset | partition_id | from    | to       | payload                 | acknowledged |
| ------ | ------------ | ------- | -------- | ----------------------- | ------------ |
| 0      | chat_a       | paul@id | device_1 | Hello from device_1 - 1 | false        |
| 1      | chat_a       | paul@id | device_1 | Hello from device_1 - 2 | false        |
| 2      | chat_a       | paul@id | device_2 | Hello from device_2 - 1 | false        |
| 3      | chat_a       | paul@id | device_3 | Hello from device_3 - 1 | false        |

Initial **index** (shared per partition and sender):

| partition_id | from    | next_offset |
| ------------ | ------- | ----------- |
| chat_a       | paul@id | 4           |

---

### **Step 1: Device fetch**

Device 1 fetches messages starting from offset 0:

```elixir
{:ok, messages, next_offset} = BimipQueue.fetch_unack("paul@id", "chat_a", "paul@id", "device_1", 10, 0)
```

**Resulting messages for device_1:**

| offset | payload                 | acknowledged |
| ------ | ----------------------- | ------------ |
| 0      | Hello from device_1 - 1 | false        |
| 1      | Hello from device_1 - 2 | false        |

**`next_offset` returned**: 2

- You can now **update the index next_offset** if you want the next fetch to start from 2.

---

### **Step 2: Device 2 fetches**

Device 2 fetches messages starting from offset 0 (shared index not yet updated):

```elixir
{:ok, messages, next_offset} = BimipQueue.fetch_unack("paul@id", "chat_a", "paul@id", "device_2", 10, 0)
```

**Resulting messages for device_2:**

| offset | payload                 | acknowledged |
| ------ | ----------------------- | ------------ |
| 2      | Hello from device_2 - 1 | false        |

**`next_offset` returned**: 3

- Again, **index next_offset can be updated to 3** for shared tracking.

---

### **Step 3: Device 1 acknowledges message**

Device 1 acknowledges message at offset 0:

```elixir
BimipQueue.ack("paul@id", "chat_a", "paul@id", "device_1", 0)
```

Queue now looks like this:

| offset | payload                 | acknowledged |
| ------ | ----------------------- | ------------ |
| 0      | Hello from device_1 - 1 | true         |
| 1      | Hello from device_1 - 2 | false        |
| 2      | Hello from device_2 - 1 | false        |
| 3      | Hello from device_3 - 1 | false        |

**Important:** `next_offset` in the index is **unchanged**.

- Fetch offset only moves when a device fetches.
- Ack only changes message state.

---

### **Step 4: Device 2 fetches again**

Device 2 fetches from `next_offset = 3` (index updated after its last fetch):

```elixir
{:ok, messages, next_offset} = BimipQueue.fetch_unack("paul@id", "chat_a", "paul@id", "device_2", 10, 3)
```

**Resulting messages for device_2:**

| offset | payload                 | acknowledged |
| ------ | ----------------------- | ------------ |
| 3      | Hello from device_3 - 1 | false        |

- Device 2 did **not see offset 0** because it’s already acknowledged by device 1 and offset 0 < 3.
- `next_offset` becomes 4 (end of queue).

---

### **Key Takeaways for Implementation**

1. **Shared next_offset per partition**:

   - Keeps track of the “fetch cursor” for all devices.
   - Prevents duplicate fetching across devices.

2. **Ack is separate**:

   - Only marks messages as acknowledged.
   - Does not move the fetch cursor.

3. **Device fetch flow**:

   - Fetch from `next_offset` stored in index.
   - Update `next_offset` in index after fetch if needed.

4. **Device ack flow**:

   - Ack messages individually or in batch.
   - Messages remain in queue for other devices until all relevant devices have acked (optional fan-out logic).

---

If you want, I can **draw a timeline diagram with offsets, fetch, and ack for three devices** so you can paste directly in documentation.

Do you want me to do that?
