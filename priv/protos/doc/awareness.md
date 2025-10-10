# 🧠 Awareness Stanza

## **Purpose**

The **Awareness Stanza** provides a unified, efficient structure for expressing both **user-level** and **system-level** awareness in real-time systems.
It uses a **fire-and-forget** model: short-lived, non-persistent updates that expire automatically after a defined **TTL (Time-To-Live)** duration.

This design simplifies signaling like _typing_, _recording_, or _presence_ while remaining bandwidth-efficient and latency-safe.

---

## **1. Core Design Rules**

- **Fire-and-Forget:**
  Awareness messages are transient — not stored or retried.

- **TTL Enforcement:**
  The `ttl` field defines how long a message is valid.
  Clients and servers both check TTL to avoid delivering outdated states.

- **Automatic Expiry:**
  Awareness automatically ends when its TTL expires.
  No explicit `START` or `STOP` fields are required.

- **Implicit Type Detection:**
  The `status` code defines whether it’s **User Awareness** or **System Awareness** — no category field is needed.

- **Priority Handling:**

  - If the last user awareness is `1 = ENABLED` (location shared), user awareness takes precedence.
  - Ping-pong or system awareness aligns with or defers to that configuration.

- **Scope Difference:**

  - **User Awareness → Targeted to one subscriber (individual recipient)**
  - **System Awareness → Broadcast to all subscribers (all active peers)**

---

## **2. Awareness Type Definitions**

### **A. User Awareness (Private / Single Recipient)**

Represents an individual user’s visibility or status, intended for **one subscriber** (e.g., contact or chat partner).

| **Code** | **Label**   | **Description**                   | **Recommended TTL (s)** | **Visibility**    |
| :------: | :---------- | :-------------------------------- | :---------------------: | :---------------- |
|   `1`    | **ONLINE**  | User is connected and active      |         60–120          | Single subscriber |
|   `2`    | **OFFLINE** | User disconnected                 |            0            | Single subscriber |
|   `3`    | **AWAY**    | User inactive for a period        |         120–300         | Single subscriber |
|   `4`    | **BUSY**    | User is active but engaged        |         120–300         | Single subscriber |
|   `5`    | **DND**     | Do Not Disturb (no notifications) |         120–300         | Single subscriber |

---

### **B. System Awareness (Broadcast / All Subscribers)**

Represents short-lived, system-wide events such as typing or recording — visible to **all subscribers** of the user.

| **Code** | **Label**     | **Description**               | **Recommended TTL (s)** | **Visibility** |
| :------: | :------------ | :---------------------------- | :---------------------: | :------------- |
|   `6`    | **TYPING**    | User is typing a message      |           3–5           | Broadcast      |
|   `7`    | **RECORDING** | User is recording audio/video |          5–10           | Broadcast      |
|   `8`    | **LISTENING** | User is listening to audio    |          5–10           | Broadcast      |
|   `9`    | **UPLOADING** | User is uploading data/media  |          5–15           | Broadcast      |

> 💡 **Note:**
>
> - `status` defines whether awareness is user or system.
> - The server uses routing rules:
>
>   - If `status <= 5` → deliver to **single subscriber**.
>   - If `status >= 6` → broadcast to **all subscribers**.

---

## **3. Location Sharing Configuration**

Location visibility is controlled by an integer field for clarity and compatibility.

| **Field** | **Value**    | **Meaning**                     |
| :-------- | :----------- | :------------------------------ |
| `1`       | **ENABLED**  | User allows location broadcast  |
| `2`       | **DISABLED** | User hides location information |

If `location_sharing = 1`, `latitude` and `longitude` are included and expire based on `ttl`.

---

## **4. Ping-Pong Interaction**

- **Ping-Pong awareness** (system heartbeat) respects user settings:

  - If user’s last awareness = `1 (ENABLED)` → ping-pong follows and updates.
  - If `2 (DISABLED)` → ping-pong is ignored or suspended.

This ensures consistent awareness state synchronization.

---

## **5. Message Schema**

```proto
// ---------------- Awareness ----------------
// Represents both user and system awareness (presence or activity).
//
// Usage Notes:
// - System Awareness (broadcast): status → 6=TYPING, 7=RECORDING, etc.
// - User Awareness (targeted): status → 1=ONLINE, 2=OFFLINE, 3=AWAY, 4=BUSY, 5=DND
// - location_sharing: 1=ENABLED, 2=DISABLED
// - ttl: defines message lifespan before expiry
// - Fire-and-forget: no acknowledgment required
// - Server delivery: user awareness → single target; system awareness → all subscribers
// - Ping-pong aligns with user's last awareness if ENABLED.
//
message Awareness {
  string from = 1;               // Sender EID
  string to = 2;                 // Recipient EID (used for user awareness)
  int32 status = 3;              // Awareness state (see tables above)
  int32 location_sharing = 4;    // 1=ENABLED, 2=DISABLED
  double latitude = 5;           // Latitude (optional)
  double longitude = 6;          // Longitude (optional)
  int64 timestamp = 7;           // Epoch time (ms)
  int32 ttl = 8;                 // Time-to-live (seconds)
}
```

---

## **6. Behavioral Summary**

| **Condition**          | **Action**                               |
| ---------------------- | ---------------------------------------- |
| TTL expires            | Awareness auto-removed (no manual reset) |
| Stale packet arrives   | Ignored silently                         |
| New awareness received | Replaces previous state                  |
| User awareness active  | Ping-pong aligns with user preference    |
| `status <= 5`          | Delivered to single subscriber           |
| `status >= 6`          | Broadcast to all subscribers             |
