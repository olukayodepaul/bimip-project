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

## **2. `signal_offset `**

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
1 = ACKLODGEMENT
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

## **9. `signal_type (optional)`**

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

## **10. `error (optional)->Response`**

**Type:** `optional string`
**Description:**
Error message returned when `type = 3`.

**Purpose:**
Provides details on invalid requests or system errors.

---

## **11. `signal_lifecycle_state (optional)`**

**Type:** `string`
**Description:**
use to transpose`signal_ack_state` **from difference state**.

### Meaning:

* **delivered** → indicate message delivering and forward offset .
* **read** → indicate message is read also kind of move offset forward.

### Required Client Behavior:

* All messages must eventually move forward.
* If `false`, the **client must retry** until the server returns `true`.

**Purpose:**
Guarantees strict ordering and prevents offset gaps.

---

## **12. `signal_ack_state`**

* **Type:** SignalAckState
* **Description:** Tracks acknowledgment lifecycle of a signal.

```proto
message SignalAckState {
  bool send = 1;     
  bool received = 2; 
  bool read = 3;     
}
```

---
## **13. `signal_direction`**

**Type:** `int`
Track if message receive is either pull or push request.

### Purpose:

Represents message delivery channel:

* pull: 1 -> after advancing offset, fetch next message
* push: 2 -> after advancing offser, do not fetch next message

Ensures consistent UI and device synchronization.

---
## **14. `signal_type_ex`**

**Type:** `int`
Tell server is request is to advance offset or message ack.

### Purpose:

Represents message delivery channel:

* Advance offset (System Level): 1 -> for advancing offset
* Message ack state (User Level): 2 -> use for message acknowledgent


---
## **Proto**

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
  string signal_lifecycle_state = 11;   
  SignalAckState signal_ack_state = 12;
  int32 signal_request = 13;
}
```
---
**ACK AND SENDER for pulling message ack statt**
```
ack_signal = %Bimip.Signal{
  id: "1",
  signal_offset: 1,
  user_offset: 1,
  status: 1,  
  timestamp: System.system_time(:second),
  from: %Bimip.Identity{eid: "b@domain.com"},
  to: %Bimip.Identity{eid: "a@domain.com"},
  type: 1,            # 1 = REQUEST
  signal_type: 3,      # 2 = DEVICE
  signal_lifecycle_state: "read"
}

ack_message = %Bimip.MessageScheme{
  route: 7,           # ACK signaling route
  payload: {:signal, ack_signal}
}

binary_ack = Bimip.MessageScheme.encode(ack_message)
hex_ack = Base.encode16(binary_ack, case: :upper)

```


***Resume data***
```proto 
ack_signal = %Bimip.Signal{
  status: 7,
  timestamp: System.system_time(:second),
  to: %Bimip.Identity{
    eid: "a@domain.com"
  },
  type: 1
}

ack_message = %Bimip.MessageScheme{
  route: 7,               # route for signaling/ack messages
  payload: {:signal, ack_signal}
}

binary_ack = Bimip.MessageScheme.encode(ack_message)
hex_ack = Base.encode16(binary_ack, case: :upper)
```


***Forward/advance Offset data***
This is to self. signal_type_ex: 1, is forward offself and it is to self..
```proto 
ack_signal = %Bimip.Signal{
  signal_offset: 4,
  status: 1,
  type: 1,
  timestamp: System.system_time(:second),
  to: %Bimip.Identity{
    eid: "a@domain.com"
  },
  signal_type_ex: 1,
}

ack_message = %Bimip.MessageScheme{
  route: 7,               # route for signaling/ack messages
  payload: {:signal, ack_signal}
}

binary_ack = Bimip.MessageScheme.encode(ack_message)
hex_ack = Base.encode16(binary_ack, case: :upper)

```

---
***delivered Message***
This is to self. signal_type_ex: 1, is forward offself and it is to self..
```proto 
ack_signal = %Bimip.Signal{
  status: 1,
  type: 1,
  timestamp: System.system_time(:second),
  to: %Bimip.Identity{
    eid: "b@domain.com"
  },
  batched_acks: [
    %Bimip.BatchedOffset{
      user_offset: 1,
      offset: 1,
      timestamp: System.system_time(:second),
      owners: %Bimip.OWNERS{
        from: "a@domain.com",
        to: "b@domain.com"
      },
      delivery_ack: %Bimip.DeliveryAck{
        sent: true,
        sent_timestamp: System.system_time(:second)
      },
      signal_type: 3,
    },
    %Bimip.BatchedOffset{
      user_offset: 2,
      offset: 2,
      timestamp: System.system_time(:second),
      owners: %Bimip.OWNERS{
        from: "a@domain.com",
        to: "b@domain.com"
      },
      delivery_ack: %Bimip.DeliveryAck{
        sent: true,
        sent_timestamp: System.system_time(:second)
      },
      signal_type: 3,
    },
     %Bimip.BatchedOffset{
      user_offset: 3,
      offset: 3,
      timestamp: System.system_time(:second),
      owners: %Bimip.OWNERS{
        from: "a@domain.com",
        to: "b@domain.com"
      },
      delivery_ack: %Bimip.DeliveryAck{
        sent: true,
        sent_timestamp: System.system_time(:second)
      },
      signal_type: 3,
    },

    %Bimip.BatchedOffset{
      user_offset: 1,
      offset: 4,
      timestamp: System.system_time(:second),
      owners: %Bimip.OWNERS{
        from: "c@domain.com",
        to: "b@domain.com"
      },
      delivery_ack: %Bimip.DeliveryAck{
        sent: true,
        sent_timestamp: System.system_time(:second)
      },
      signal_type: 3,
    },

     %Bimip.BatchedOffset{
      user_offset: 1,
      offset: 5,
      timestamp: System.system_time(:second),
      owners: %Bimip.OWNERS{
        from: "e@domain.com",
        to: "b@domain.com"
      },
      delivery_ack: %Bimip.DeliveryAck{
        sent: true,
        sent_timestamp: System.system_time(:second)
      },
      signal_type: 3,
    },

  ],
  signal_type_ex: 3,
}

ack_message = %Bimip.MessageScheme{
  route: 7,               # route for signaling/ack messages
  payload: {:signal, ack_signal}
}

binary_ack = Bimip.MessageScheme.encode(ack_message)
hex_ack = Base.encode16(binary_ack, case: :upper)


08073A1B2001288ECBABC9063A0D0A0B40646F6D61696E2E636F6D40017001