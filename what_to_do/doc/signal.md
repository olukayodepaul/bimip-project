# **📘 Signal Message — Full Field Documentation**

The **Signal** message is used for real-time synchronization between sender, receiver, and devices.
It ensures strict ordering, reliable offset progression, and consistent message acknowledgment across distributed systems.

---

# **Field-by-Field Specification**

---

## **1. `id`**

**Type:** `string`
**Description:**
Client-generated unique message ID.
Used to track the message before the server assigns offsets.

**Purpose:**

* Allows reconciliation between local message and server acknowledgment
* Prevents client-side duplication
* Required for retry logic

---

## **2. `signal_offset`**

**Type:** `int32`
**Description:**
Server-assigned offset that is **unique per receiver queue**.

**Characteristics:**

* Monotonically increasing
* Every receiver has its own independent offset sequence
* Defines the exact order in which the receiver will process signals

**Purpose:**
Provides strict, ordered message delivery.

---

## **3. `user_offset`**

**Type:** `int32`
**Description:**
Offset used to synchronize both sender and receiver in a **shared conversation**.

**Characteristics:**

* Uniform for sender and receiver
* Helps reconcile cross-device or multi-session activity
* Used for global conversation ordering

**Purpose:**
Ensures both sides are aligned on the conversation timeline.

---

## **4. `status`**

**Type:** `int32`
**Description:**
Represents user actions or system events in real time.

**Status Codes:**

```
1 = CHATTING
2 = RECORDING
3 = PLAYED/VIEWED
4 = TYPING
5 = PAUSED
6 = CANCELLED
7 = RESUME
8 = NOTIFICATION
```

**Purpose:**
Allows clients to track typing, recording, viewing, notifications, etc.

---

## **5. `timestamp`**

**Type:** `int64` (epoch ms)
**Description:**
Timestamp when the signal was generated.

**Purpose:**
Used for ordering, display, auditing, and recovery after reconnect.

---

## **6. `from`**

**Type:** `Identity`
**Description:**
The sender of the signal.

**Purpose:**
Identifies which user/device originated the event or acknowledgment.

---

## **7. `to`**

**Type:** `Identity`
**Description:**
The receiver of the signal.

**Purpose:**
Determines routing and offset progression rules.

---

## **8. `type`**

**Type:** `int32`
**Description:**
Direction or classification of the signal.

**Types:**

```
1 = REQUEST      → Client → Server
2 = RESPONSE     → Server → Client
3 = ERROR        → Server → Client (failed request)
```

**Purpose:**
Separates new requests from server responses and error events.

---

## **9. `signal_type`**

**Type:** `int32`
**Description:**
Indicates which entity generated the signal and how it is interpreted.

**Types:**

```
1 = SENDER     → Original sender of the action
2 = DEVICE     → Device-level sync (multi-device)
3 = RECEIVER   → Receiver reconciliation signal
```

**Purpose:**
Allows proper handling in multi-device, multi-session, or mirrored conversations.

---

## **10. `error`**

**Type:** `optional string`
**Description:**
Error message returned when `type = 3`.

**Purpose:**
Provides details on invalid requests or system errors.

---

## **11. `signal_offset_state`**

**Type:** `bool`
**Description:**
Indicates whether the `signal_offset` **successfully moved forward**.

### Meaning:

* **true** → Offset advanced. Message placed in receiver’s sequence.
* **false** → Offset not advanced (duplicate, out-of-order, or waiting for retry).

### Required Client Behavior:

* All messages must eventually move forward.
* If `false`, the **client must retry** until the server returns `true`.

**Purpose:**
Guarantees strict ordering and prevents offset gaps.

---

## **12. `signal_ack_state`**

**Type:** `SignalAckState`
**Description:**
Defines the acknowledgment status of the signal.

**Examples (your system may define exact enum values):**

```
PENDING
RECEIVED
PROCESSED
FAILED
RETRYING
```

**Purpose:**
Allows both client and server to track whether a message has been:

* delivered
* processed
* requires retry
* failed

Enhances reliability and message-queue integrity.


---
Perfect! Let’s create the **complete Messaging Protocol Specification v1.0 section specifically for Signal**, just like we did for Message. This will cover all fields, statuses, offsets, acknowledgments, and behavior.

---

# **Signal — Complete Protocol Specification**

The **Signal** message is used for **real-time synchronization** between sender, receiver, and devices.
It tracks **message status, offsets, acknowledgments, and user activity**, ensuring consistent behavior across multi-device setups.

---

## **1. Overview**

* Signals are **system messages** that track the lifecycle of chat messages or notifications.
* Used to update **delivery, read, and status information**.
* Supports **dual referencing** by `id` and `signal_offset` to reconcile message state.
* Handles **user activity awareness** like typing or recording.

---

## **2. Signal Flow**

**Sender → Server → Receiver → Sender ACK**

1. **Sender** emits a signal to report an action or request acknowledgment.
2. **Server** assigns `signal_offset` and `user_offset`, records status, and may respond.
3. **Receiver** processes the signal and updates local state.
4. **Server** propagates acknowledgment back to sender.
5. **Client** updates the local Signal state based on `signal_offset_state` and `signal_ack_state`.

---

## **3. Signal Schema**

```proto
message Signal {
  string id = 1;            
  int32 signal_offset = 2; 
  int32 user_offset = 3;   
  int32 status = 4;     
  int64 timestamp = 5;      
  Identity from = 6;        
  Identity to = 7;          
  int32 type = 8;           
  int32 signal_type = 9;    
  optional string error = 10;
  bool signal_offset_state = 11;   
  SignalAckState signal_ack_state = 12;
}
```

---

## **4. Field-by-Field Explanation**

### **1. `id`**

* **Type:** string
* **Description:** Client-generated unique ID for the signal.
* Used to reconcile signals between client and server.

---

### **2. `signal_offset`**

* **Type:** int32
* **Description:** Server-assigned unique per-receiver offset.
* Monotonically increasing to enforce strict message order.

---

### **3. `user_offset`**

* **Type:** int32
* **Description:** Conversation-level offset shared between sender and receiver.
* Ensures synchronized conversation timeline across devices.

---

### **4. `status`**

* **Type:** int32
* **Description:** Real-time user activity or system state.

| Value | Meaning       |
| ----- | ------------- |
| 1     | CHATTING      |
| 2     | RECORDING     |
| 3     | PLAYED/VIEWED |
| 4     | TYPING        |
| 5     | PAUSED        |
| 6     | CANCELLED     |
| 7     | RESUME        |
| 8     | NOTIFICATION  |

---

### **5. `timestamp`**

* **Type:** int64 (epoch ms)
* **Description:** When the signal was generated.
* Used for ordering, conflict resolution, and auditing.

---

### **6. `from`**

* **Type:** Identity
* **Description:** Sender of the signal.

---

### **7. `to`**

* **Type:** Identity
* **Description:** Receiver of the signal.

---

### **8. `type`**

* **Type:** int32
* **Description:** Direction or classification of the signal.

| Value | Meaning                    |
| ----- | -------------------------- |
| 1     | REQUEST (Client → Server)  |
| 2     | RESPONSE (Server → Client) |
| 3     | ERROR (Server → Client)    |

---

### **9. `signal_type`**

* **Type:** int32
* **Description:** Indicates signal context for multi-device synchronization.

| Value | Meaning  |
| ----- | -------- |
| 1     | SENDER   |
| 2     | DEVICE   |
| 3     | RECEIVER |

---

### **10. `error`**

* **Type:** optional string
* **Description:** Error message for type=ERROR signals.

---

### **11. `signal_offset_state`**

* **Type:** bool
* **Description:** Indicates whether the server successfully advanced the receiver’s offset.

**Meaning:**

* **true:** Offset moved forward; message/signal is accepted in order.
* **false:** Offset did not move forward (duplicate, out-of-order, or pending).

**Client Rule:**
If false, **client must retry** until the server confirms offset advancement.

---

### **12. `signal_ack_state`**

* **Type:** SignalAckState
* **Description:** Tracks acknowledgment lifecycle of a signal.

```proto
message SignalAckState {
  bool send = 1;     
  bool received = 2; 
  bool read = 3;     
}
```

**Meaning of fields:**

* `send`: Signal accepted by server
* `received`: Signal delivered to receiver device
* `read`: Signal processed/read by receiver

---

## **5. Signal Behavior**

* Signals support **multi-device synchronization** and **status updates**.
* Awareness events like typing or recording are handled per-user and transmitted via signal.
* Retry logic ensures no offsets are skipped and all signals eventually move forward.
* Errors propagate via `Signal.type=3` and `error` message.

---

## **6. Security Considerations**

* Signals may include cryptographic verification if required (e.g., device identity or signed events).
* No sensitive payload is transmitted in `Signal` directly; content is carried in `Message`.

---

## **7. Offset & Retry Rules**

* **All offsets must move forward**.
* If `signal_offset_state = false`, client **must retry**.
* Supports gapless, monotonic sequence for accurate state reconciliation.

---

## **8. Status & Awareness**

Signals allow tracking:

* Real-time activity (`status` field)
* Message acknowledgments (`signal_ack_state`)
* Per-device and per-user states

This ensures accurate UI feedback and conversation consistency.

---

✅ **Summary:**
The Signal protocol ensures:

* Reliable state synchronization
* Ordered offset tracking
* Full acknowledgment lifecycle
* Multi-device consistency
* Real-time awareness of user actions

---

If you want, I can now **combine both Message + Signal into a single full Messaging Protocol Spec with diagrams**, showing the **full lifecycle from sender → server → receiver → acknowledgments**. This would be a fully professional spec ready for your team or GitHub.

Do you want me to do that next?
