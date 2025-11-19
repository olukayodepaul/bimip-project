
# 📘 **Message — Complete Field Documentation**

The **Message** structure represents a single chat, media, or notification message exchanged between users.
It is transmitted **once**, and all delivery tracking (sent, delivered, read), offsets, retries, and synchronization are handled through accompanying Signal messages.

This ensures reliable, ordered, secure communication across multiple devices and network conditions.

---

# **Message — Field-by-Field Specification**

---

## **1. `id`**

**Type:** `string`
Client-generated unique message ID.

**Purpose:**

* Allows client-side tracking before server assigns offsets
* Used for retries and de-duplication
* Links Message to its acknowledgment Signals

---

## **2. `signal_offset`**

**Type:** `int32`
Server-assigned offset unique per receiver queue.

**Characteristics:**

* Strictly increasing
* Defines receiver’s message order
* Each user has their own offset sequence

**Purpose:**
Ensures perfect message ordering.

---

## **3. `user_offset`**

**Type:** `int32`
Shared conversation-level offset between sender and receiver.

**Purpose:**
Synchronizes both ends of the conversation timeline.

---

## **4. `from`**

**Type:** `Identity`
Sender identity (JID, user ID, or device ID).

---

## **5. `to`**

**Type:** `Identity`
Receiver identity.

---

## **6. (Intentionally unused)**

Safe, allowed by protobuf. No documentation required.

---

## **7. `timestamp`**

**Type:** `int64` (epoch ms)
Message creation time on the client.

---

## **8. `payload`**

**Type:** `bytes`
Raw message content encoded as JSON or structured bytes.

**Examples:**

* Text: `{ "type": "text", "body": "Hello" }`
* Image: `{ "type": "image", "url": "..." }`
* Call events
* System events

**Purpose:**
Flexible for any message type.

---

## **9. `encryption_type`**

**Type:** `string`
Encryption mode used for this message.

Example values:

```
"none"
"AES256"
"E2E"
"CUSTOM"
```

---

## **10. `encrypted`**

**Type:** `string` (base64)
Encrypted version of the payload (if encryption is used).

---

## **11. `signature`**

**Type:** `string` (base64)
Digital signature for validating integrity and sender authenticity.

---

## **12. `signal_type`**

**Type:** `int32`
Indicates the context in which the message is being synchronized.

Values:

```
1 = SENDER
2 = DEVICE
3 = RECEIVER
```

---

## **13. `signal_offset_state`**

**Type:** `bool**
Indicates whether the server successfully advanced the receiver’s message offset.

### Meaning:

* **true** → Offset advanced (message accepted in order)
* **false** → Offset NOT advanced (duplicate, out-of-order, retry required)

**Client Rule:**
If `false`, the client **must retry the same message** until the server returns `true`.

---



## **14. `signal_ack_state`**

**Type:** `SignalAckState`
Tracks the acknowledgment stage of the message across sender, server, and receiver.

### Purpose:

Represents message delivery lifecycle:

* sent
* delivered
* read

Ensures consistent UI and device synchronization.

---

## **15. `signal_request`**

**Type:** `int`
Track if message receive is either pull or push request.

### Purpose:

Represents message delivery channel:

* pull: 1 -> after advancing offset, fetch next message
* push: 2 -> after advancing offser, do not fetch next message

Ensures consistent UI and device synchronization.

---

# 📘 **SignalAckState — Complete Documentation**

```proto
message SignalAckState {
  bool send = 1;
  bool received = 2;
  bool read = 3;
}
```

---

## **1. `send`**

**Type:** `bool`
Indicates message is successfully **sent to and accepted by the server**.

Triggers:

* Client uploads message
* Server stores it and assigns offsets

UI example:
✓ Sent

---

## **2. `received`**

**Type:** `bool`
Indicates message is **delivered to the receiver’s device**.

Triggers:

* Server pushes message to receiver
* Receiver confirms delivery

UI example:
✓✓ Delivered

---

## **3. `read`**

**Type:** `bool`
Indicates the message is **opened/read/viewed by the receiver**.

Triggers:

* Receiver opens chat
* Receiver’s client reports read receipt

UI example:
👁️ Seen / Read




---
Perfect! Let’s put together a **complete Messaging Protocol Specification v1.0** based on all your work so far.

Here’s the full structured draft:

---

# **Messaging Protocol Specification v1.0**

**Purpose:**
This document defines the message and signal protocol used for real-time chat, notifications, and multi-device synchronization.
It ensures **reliable delivery, strict ordering, acknowledgment tracking, and encryption** across clients and servers.

---

## **1. Overview**

* Messages are exchanged between users/devices in real-time.
* Signals are used to **acknowledge, track status, and reconcile offsets**.
* Each message is sent once; acknowledgments and retries are handled via Signals.
* Supports multi-device synchronization and end-to-end encryption.

---

## **2. Transport Model**

* Messages and signals are sent over **persistent connections** (WebSocket, MQTT, or other real-time transport).
* Each device maintains its own **receiver queue** for ordered message delivery.
* Offsets are used to **guarantee ordering** and **prevent duplicates**.

---

## **3. Message Flow**

**Sender → Server → Receiver → Sender ACK**

1. **Sender** generates a `Message` with `id`, `payload`, and optional encryption.
2. **Server** assigns `signal_offset` and `user_offset`.
3. **Receiver** accepts message in order and updates `signal_offset_state`.
4. **Receiver** acknowledges receipt via `SignalAckState` (send, received, read).
5. **Sender** updates local message state when acknowledgment is received.

---

## **4. Message Schema**

```proto
message Message {
  string id = 1;
  int32 signal_offset = 2;
  int32 user_offset = 3;
  Identity from = 4;
  Identity to = 5;
  int64 timestamp = 7;
  bytes payload = 8;
  string encryption_type = 9;
  string encrypted = 10;
  string signature = 11;
  int32 signal_type = 12;           
  bool signal_offset_state = 13;    
  SignalAckState signal_ack_state = 14;
  int32 signal_request = 15;
}
```

**Field Explanations:**

* `id`: Client-generated unique ID for deduplication and retry.
* `signal_offset`: Receiver queue offset, strictly increasing.
* `user_offset`: Conversation-level offset shared between sender & receiver.
* `from` / `to`: Sender and recipient identity.
* `timestamp`: Epoch milliseconds of creation.
* `payload`: Structured content (JSON or bytes).
* `encryption_type`: "none", "AES256", "E2E", etc.
* `encrypted`: Base64 encrypted payload.
* `signature`: Base64 digital signature for integrity.
* `signal_type`: 1=SENDER, 2=DEVICE, 3=RECEIVER.
* `signal_offset_state`: True if server advanced the offset; false if client must retry.
* `signal_ack_state`: Tracks lifecycle (send, received, read).

---

## **5. Signal Schema**

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

**Field Highlights:**

* `status`: Real-time activity (Typing, Recording, Paused, etc).
* `type`: 1=REQUEST, 2=RESPONSE, 3=ERROR.
* `signal_offset_state`: Ensures all offsets move forward; client retries until `true`.
* `signal_ack_state`: Tracks message lifecycle.

---

## **6. SignalAckState**

```proto
message SignalAckState {
  bool send = 1;     
  bool received = 2; 
  bool read = 3;     
}
```

**Meaning:**

* `send`: Server accepted the message.
* `received`: Receiver device accepted the message.
* `read`: Receiver opened/read the message.

**Purpose:**
Ensures consistent message delivery tracking and UI states across devices.

---

## **7. Status Codes**

| Value | Status        | Meaning                     |
| ----- | ------------- | --------------------------- |
| 1     | CHATTING      | User actively chatting      |
| 2     | RECORDING     | Recording audio/video       |
| 3     | PLAYED/VIEWED | Media/message has been seen |
| 4     | TYPING        | User typing                 |
| 5     | PAUSED        | Typing/recording paused     |
| 6     | CANCELLED     | Action cancelled            |
| 7     | RESUME        | Action resumed              |
| 8     | NOTIFICATION  | System/app notification     |

---

## **8. Offset & Retry Rules**

* **All message offsets must move forward.**
* If `signal_offset_state = false`, client must **retry** sending until true.
* Ensures strict monotonic order and prevents lost messages.

---

## **9. Security Model**

* Messages may be encrypted: `AES256`, `E2E`, or other.
* Signature ensures integrity and authenticity.
* End-to-end encryption is optional depending on system design.

---

## **10. Multi-Device Sync**

* Each device has its own receiver queue.
* Signal offsets ensure proper reconciliation between sender, receiver, and devices.
* `signal_type` helps distinguish SENDER, DEVICE, RECEIVER signals.
* Signals propagate acknowledgment to all active devices.

---

## **11. Error Handling**

* `Signal.type = 3` → Error
* `Signal.error` contains descriptive error message
* Clients retry until offsets are advanced or error resolved

---

## **12. Notes**

* Awareness signals (Typing, Recording) are **per-user** and sent separately; they do not generate multiple message copies.
* Payloads can carry any structured data, including system events, media references, or JSON objects.
* This protocol is **transport-agnostic** but designed for WebSocket or other persistent real-time channels.

---

# ✅ **Messaging Protocol Summary**

This protocol ensures:

* Reliable delivery
* Ordered message sequences
* Multi-device consistency
* Retry and offset reconciliation
* End-to-end integrity and optional encryption
* Real-time activity awareness
* Strong ACK and status tracking


