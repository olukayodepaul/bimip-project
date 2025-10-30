## ✅ **Full Awareness Visibility Workflow**

### 1️⃣ **User toggles awareness visibility**

- A user on one device (say device A) sends:
  `AwarenessVisibility { id, from, type = 1 or 2 }`
- This message goes **from bimipSignal → bimipServer**.

---

### 2️⃣ **bimipServer updates the user’s visibility state**

- `bimipServer` stores the **new state** (ENABLED or DISABLED) for that user.
- This becomes the **source of truth** for all devices and all future sessions.

---

### 3️⃣ **bimipServer broadcasts the visibility change to all user devices**

- Send a **ThrowAwarenessVisibilitySchema.success()** message to:

  - the **origin device** (acknowledgement),

  - and all **other devices** of the same user (synchronization).

  > 🔸 All user devices will now reflect the same visibility state.

---

### 4️⃣ **bimipSignal updates local broadcast behavior**

Each device’s `bimipSignal` instance now:

- **Disables awareness signals** if `type = 2 (DISABLED)` → stops sending `ONLINE`, `TYPING`, `READ`, etc.
- **Re-enables awareness signals** if `type = 1 (ENABLED)` → resumes normal broadcast.

---

### 5️⃣ **bimipServer updates shared awareness state for new sessions**

- When the user **logs in again (new session)**, `bimipServer` includes the **current visibility state** in the login response.
  That ensures the new session immediately obeys the same rule.

---

### 6️⃣ **(Optional but Recommended)** — **Server notifies contacts (roster) if visibility changes**

If you want to make it more interactive:

- When a user disables visibility (`DISABLED`), server can send a **“presence offline”** update to the user’s contacts.
- When re-enabled, it can send a **“presence online”** update again.

_(This step depends on your product’s privacy policy — some systems don’t notify contacts when visibility changes.)_

---

### 🔹 Summary of Responsibilities

| Component                     | Responsibility                                                                |
| ----------------------------- | ----------------------------------------------------------------------------- |
| **bimipSignal (client node)** | Sends visibility toggle request and updates local behavior.                   |
| **bimipServer**               | Maintains global truth of user visibility, broadcasts updates to all devices. |
| **All user devices**          | Mirror visibility state and adjust broadcast behavior accordingly.            |
| **(Optional)**                | Inform roster contacts depending on privacy policy.                           |

---

Would you like me to show how to implement **step 4** — i.e., how each `bimipSignal` instance should suppress all awareness broadcasts once visibility is disabled?

```
request = %Bimip.AwarenessVisibility{
  id: "1",
  from: %Bimip.Identity{
    eid: "a@domain.com",
    connection_resource_id: "aaaaa1"
  },
  type: 1,  # 1 = ENABLED (means user wants to hide awareness)
  timestamp: System.system_time(:millisecond)
}

msg_request = %Bimip.MessageScheme{
  route: 4,  # Awareness route
  payload: {:awareness_visibility, request}
}

binary = Bimip.MessageScheme.encode(msg_request)
hex    = Base.encode16(binary, case: :upper)
```
