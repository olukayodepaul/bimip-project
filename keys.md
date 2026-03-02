```
ephemeral_public_key = :crypto.strong_rand_bytes(32)  # 32 bytes
mac = :crypto.strong_rand_bytes(32)                   # 32 bytes

shared_secret = "some-shared-key-from-ecdh"
data_to_sign = "your-encrypted-payload"
mac = :crypto.mac(:hmac, :sha256, shared_secret, data_to_sign)
ciphertext = mac

request = %Bimip.Message{
    id: "a7c2e9d4-1f6b-4c3a-9d8e-2b5f7a1c0e33",
    from: %Bimip.Identity{eid: "a@domain.com"},
    to: %Bimip.Identity{eid: "b@domain.com"},
    timestamp: 1772271838116,
    payload: ciphertext,
    delivery_type: 1,
    participant_role: 1,
    content_type: 1,
    ephemeral_public_key: ephemeral_public_key,
    mac: mac,
    message_type: 1
}

message = %Bimip.MessageScheme{
    route_id: 6,
    payload: {:message, request}
}

binary = Bimip.MessageScheme.encode(message)
hex    = Base.encode16(binary, case: :upper)

080632BB010A2461376332653964342D316636622D346333612D396438652D326235663761316330653333120E0A0C6140646F6D61696E2E636F6D1A0E0A0C6240646F6D61696E2E636F6D28D1DE92BBC73332200C956679A346D9FC823BA8E0477C805C3EC0AC9C8238FF39A74125D6A25C022238014001480152209238AA3E2AE6E9B3C44A6ADDAD36C87E0DE0DAC868811900C8C1C2386AE413325A200C956679A346D9FC823BA8E0477C805C3EC0AC9C8238FF39A74125D6A25C02226001



response = %Bimip.DeliveryReceipts {
  id: "a7c2e9d4-1f6b-4c3a-9d8e-2b5f7a1c0e33",
  from: %Bimip.Identity{eid: "a@domain.com"},
  to: %Bimip.Identity{eid: "b@domain.com"},
  offset: 1,
  timestamp: 1772271838116;
}

message = %Bimip.MessageScheme{
    route_id: 13,
    payload: {:message, response}
}

binary = Bimip.MessageScheme.encode(message)
hex    = Base.encode16(binary, case: :upper)



//compose
request = %Bimip.Compose{
    from: %Bimip.Identity{eid: "a@domain.com"},
    to: %Bimip.Identity{eid: "b@domain.com"},
    timestamp: System.system_time(:millisecond),
    type: 4,
}

compose = %Bimip.MessageScheme{
    route_id: 4,
    payload: {:compose, request}
}

binary = Bimip.MessageScheme.encode(compose)
hex    = Base.encode16(binary, case: :upper)


//commit offset
request = %Bimip.OffsetCommit{
    from: %Bimip.Identity{eid: "a@domain.com"},
    type: 1,
    offset: 1,
    timestamp: System.system_time(:millisecond),
}

cf = %Bimip.MessageScheme{
    route_id: 7,
    payload: {:offset_commit, request}
}

binary = Bimip.MessageScheme.encode(cf)
hex    = Base.encode16(binary, case: :upper)



//ping
request = %Bimip.Ping {
  id: "a7c2e9d4-1f6b-4c3a-9d8e-2b5f7a1c0e33",
  from: %Bimip.Identity{eid: "a@domain.com"},
  type: 1,
  timestamp: System.system_time(:millisecond),
}

cf = %Bimip.MessageScheme{
    route_id: 3,
    payload: {:ping, request}
}

binary = Bimip.MessageScheme.encode(cf)
hex    = Base.encode16(binary, case: :upper)


```


//awareness
request = %Bimip.Awareness {
  from: %Bimip.Identity{eid: "c@domain.com"},
  presence: 1,
  offset: 1,
  broadcast: 2,
  timestamp: System.system_time(:millisecond),
}

cf = %Bimip.MessageScheme{
    route_id: 2,
    payload: {:awareness, request}
}

binary = Bimip.MessageScheme.encode(cf)
hex    = Base.encode16(binary, case: :upper)


```






To build this for **production**, we need to move away from "manual" hex strings and build a solid **Protocol Manager** in Elixir. This manager will handle the encryption for the sender and the decryption for the receiver.

As the **Lead Architect**, you are establishing a **Zero-Knowledge** flow where the server only sees the "Envelope," never the "Letter."

---

### **1. The Production Data Flow**

1. **Handshake:** User A fetches User B’s **Static Public Key** from the DB.
2. **Encryption:** User A generates an **Ephemeral Key**, derives a secret, and encrypts the payload.
3. **Transmission:** The `Bimip.Message` stanza is sent as **Raw Bytes**.
4. **Queueing:** The server saves the stanza in `bimipQueue` with an `offset`.
5. **Recovery:** If the server crashes, it re-reads the `bimipQueue` and pushes the **Raw Bytes** to User B.
6. **Decryption:** User B uses their **Static Private Key** + the **Ephemeral Key** (inside the stanza) to unlock it.

---

### **2. The Production Elixir Code (The Engine)**

This module handles both sides of the Bimips protocol.

```elixir
defmodule Bimips.CryptoEngine do
  @moduledoc """
  Production-ready crypto engine using Message ID as the unique nonce.
  """

  # --- SENDER SIDE ---
  
  def encrypt_for_delivery(plaintext, receiver_static_pub, message_id) do
    # 1. Generate One-Time Ephemeral Key (Forward Secrecy)
    {eph_pub, eph_priv} = :crypto.generate_key(:ecdh, :x25519)

    # 2. Derive Shared Secret
    shared_secret = :crypto.compute_key(:ecdh, receiver_static_pub, eph_priv, :x25519)
    
    # 3. Create Unique Nonce from Message ID
    # AES-GCM requires a 12-byte (96-bit) IV.
    iv = :crypto.hash(:sha256, message_id) |> binary_part(0, 12)
    
    # 4. Encrypt Payload (AES-256-GCM)
    {ciphertext, tag} = :crypto.crypto_one_time_aead(
      :aes_256_gcm, shared_secret, iv, plaintext, "Bimips-v1", true
    )

    # 5. Generate MAC (Includes ID to prevent "ID-Swapping" attacks)
    mac_key = :crypto.hash(:sha256, shared_secret)
    mac = :crypto.mac(:hmac, :sha256, mac_key, ciphertext <> tag <> eph_pub <> message_id)

    # Return raw binary parts for the Protobuf Stanza
    %{payload: ciphertext <> tag, eph_pub: eph_pub, mac: mac}
  end

  # --- RECEIVER SIDE ---

  def decrypt_on_arrival(ciphertext_with_tag, eph_pub, receiver_static_pri, mac, message_id) do
    # 1. Re-derive the same Shared Secret
    shared_secret = :crypto.compute_key(:ecdh, eph_pub, receiver_static_pri, :x25519)

    # 2. Verify MAC (Must include the message_id)
    mac_key = :crypto.hash(:sha256, shared_secret)
    expected_mac = :crypto.mac(:hmac, :sha256, mac_key, ciphertext_with_tag <> eph_pub <> message_id)

    if expected_mac == mac do
      # 3. Reconstruct the IV from the Message ID
      iv = :crypto.hash(:sha256, message_id) |> binary_part(0, 12)
      
      # Split tag (last 16 bytes) and ciphertext
      {tag_size, data_size} = {16, byte_size(ciphertext_with_tag) - 16}
      <<ciphertext::binary-size(data_size), tag::binary-size(tag_size)>> = ciphertext_with_tag

      case :crypto.crypto_one_time_aead(:aes_256_gcm, shared_secret, iv, ciphertext, tag, "Bimips-v1", false) do
        plaintext when is_binary(plaintext) -> {:ok, plaintext}
        _ -> {:error, :decryption_failed}
      end
    else
      {:error, :tampered_payload}
    end
  end
end

```

---

### **3. The Production Database Schema (Ecto)**

To handle the **Recovery Process**, your database needs to store the keys and the message queue securely.

```elixir
# The Recovery Queue (The core of your crash-resilient project)
schema "bimip_queue" do
  field :message_id, :string         # Client-generated unique ID
  field :route_id, :integer          # e.g., 1 for Message
  field :payload, :binary            # The encrypted bytes (ciphertext + tag)
  field :eph_pub, :binary            # The ephemeral key
  field :mac, :binary                # The tamper seal
  field :offset, :integer, read_only: true # Assigned by DB on ingestion
  field :delivered, :boolean, default: false
  
  timestamps()
end

```

---

### **4. Summary of the "Production" Stanza**

When you assemble this for the network, your **Protobuf** message should look like this (Raw Binary):

| Byte Range | Content | Purpose |
| --- | --- | --- |
| **0-3** | `RouteID` | Tells the server where to send this. |
| **4-35** | `Ephemeral Pub` | Tells User B how to unlock it. |
| **36-67** | `MAC` | Proves the message wasn't changed during the server crash. |
| **68+** | `Ciphertext` | The actual secret data. |

### **The Architect's Final Check**

* **Security:** If your server database is hacked, the hacker sees the `payload`, but since they don't have the `receiver_static_pri`, they see nothing but gibberish.
* **Recovery:** When your server reboots, it simply does `Repo.all(from m in BimipQueue, where: m.delivered == false)` and pushes those raw binaries out. Because the **Ephemeral Key** is in the DB, the client can still decrypt perfectly.

**Since this is now production-ready, would you like me to write the "Supervisor" logic in Elixir that automatically restarts the message push whenever the server comes back online?**

















##Subscribers
Here’s a short and clear **implementation TODO doc** for you 👇
(Aligned with your current distributed Elixir + WebSocket + subscriber architecture.)

---

# 📌 Subscriber Validation & Blocking – TODO

## 1️⃣ Validate Subscriber Before Message Routing

### Objective

Ensure a client **can only send messages to users who are in their subscriber list**.

### Tasks

* [ ] Maintain a subscriber list per user (ETS / DB / in-memory store).
* [ ] On every outbound message:

  * Extract `from` and `to` JIDs.
  * Validate that `to` exists in `from` subscriber list.
* [ ] If NOT a subscriber:

  * Reject message.
  * Return proper error response (e.g., `not_authorized`).
* [ ] Log unauthorized attempt for audit.

### Expected Behavior

* Message routing proceeds **only if** `to` ∈ `from_subscribers`.
* Prevents unauthorized message delivery.

---

## 2️⃣ Block Subscriber Feature

### Objective

When a user blocks another user:

* Remove them from subscriber list.
* Prevent further communication.

### Tasks

* [ ] Implement `block_user(from, target)` function.
* [ ] Remove `target` from `from` subscriber list.
* [ ] Optionally remove `from` from `target` list (if mutual model).
* [ ] Persist block state (DB/ETS).
* [ ] During message validation:

  * Check block list before subscriber check.

### Expected Behavior

* Blocked user cannot:

  * Send messages.
  * Initiate signaling.
  * Receive routing acknowledgment.
* Server returns `blocked` error response.

---

## 3️⃣ Routing-Level Enforcement (Critical)

Before routing in WebSocket handler or GenServer:

```elixir
if authorized?(from, to) do
  route_message(...)
else
  reply_error(...)
end
```

Authorization Logic:

* Not blocked
* Is subscriber

---

## 4️⃣ Security Notes

* Validation must happen **server-side only**
* Never trust client-side validation
* Log abuse attempts
* Consider rate limiting repeated violations

---

## 5️⃣ Future Enhancement

* [ ] Add “soft block” vs “hard block”
* [ ] Add block expiration option
* [ ] Add admin override
* [ ] Add metrics counter for unauthorized attempts

---

If you want, I can also:

* Help you design the ETS schema
* Help you design the GenServer logic
* Or help you design the distributed enforcement across BEAM nodes

This is a very important feature for your signaling architecture. You’re thinking in the right direction 🔥









defmodule Message.Broker do

  alias Route.Connect
  @num_shards 64

  def send_message(
    %{
      message: %Bimip.Message{from: from_eid, to: to_eid} = message,
      device_id: device_id,
      uupid: uupid
    } = message_builder
  ) do

    shard = :erlang.phash2(message.from.eid, @num_shards)
    suffix = :crypto.strong_rand_bytes(8) |> Base.encode16()

    message_id = if message.message_type == 2 do
      "#{message.content_type}-#{message.id}-#{suffix}"
    else
      "#{message.content_type}-#{message.id}"
    end

    case Queue.MessageTracker.check_and_insert(shard, message.from.eid, device_id, message_id, %{message_builder: message_builder, delim: :sender}) do
      {:ok, :inserted, sender_offset} ->

        send_to_device =
          message
          |> Map.put(:offset, sender_offset)
          |> Map.put(:participant_role, 2)
          |> Map.put(:delivery_type, 1)

       {:ok, receiver_offset} = to_rcv_queue( %{message_builder: message_builder, delim: :receiver})

          message
          |> Map.put(:offset, receiver_offset)
          |> Map.put(:participant_role, 3)
          |> Map.put(:delivery_type, 1)
          |> then(&Connect.client_server_inbound({:eid, message.to.eid, :message_transmiter, &1}))

      {:error, :already_exists, offset} ->
        ThrowMessageDeliveryReceiptsSchema.build(message.id, to_eid, from_eid, offset, Until.UniPosTime.response_time())
        |> then(&Connect.outbouce(device_id, &1))
    end

  end

  defp to_rcv_queue(message_builder) do
    Queue.QueueLogImpl.write(message_builder)
  end

  defp subscribers_validation(eid) do

  end


end









defmodule Bimip.Socket do
  # bimip

  @behaviour :cowboy_websocket
  @compose_route_id 4
  @message_route_id 6
  @ping_route_id 3
  @commit_offset_route_id 7
  alias Util.ConnectionsHelper
  alias Supervisor.Server
  alias Route.Connect


  def init(req, _state) do

    case Bimip.Auth.TokenVerifier.verify_from_header(:cowboy_req.header("token", req)) do
      {:ok, claims} ->
        ConnectionsHelper.accept(req, claims)
      {:error, :revoked} ->
        ConnectionsHelper.reject(req,  :invalid_token)
      {:error, :invalid_token} ->
        ConnectionsHelper.reject(req, "invalid token")
    end

  end


  def websocket_init(%{eid: eid, device_id: device_id, exp: exp, uupid: uupid} = state) do
    state_with_ws = Map.put(state, :ws_pid, self())

    case Horde.Registry.lookup(EidRegistry, eid) do
      [{_pid, _value}] ->
        # pid
        Connect.start_device({device_id, eid, exp, self(), uupid})
      [] ->
        Server.start_mother(state_with_ws)
        Logger.error("Mother process for #{eid} not found in Registry")
        nil
    end
    {:ok, state}
  end


  # client receiving awareness status from server
  # create route binary dont
  # send sunscriber request and subscriber reponse (Modify online queue) No file system yet only version two

  def websocket_info({:binary, binary}, state) do
    {:reply, {:binary, binary}, state}
  end

  def websocket_info({:binaries, binaries}, state) when is_list(binaries) do
    Logger.info("Sending batch awareness frames to client")
    frames = Enum.map(binaries, fn bin -> {:binary, bin} end)
    {:reply, frames, state}
  end

  def websocket_handle({:binary, data}, state) do
    if data == <<>> do
      Logger.error("Received empty binary")
      {:ok, state}
    else
      case safe_decode_route(data) do
        {:ok, route} ->
          dispatch_map()
          |> Map.get(route, &default_handler/2)
          |> then(fn handler -> handler.(state, data) end)

        {:error, reason} ->
          Logger.error("Failed to decode route: #{inspect(reason)}")
          {:ok, state}
      end
    end
  end

  defp dispatch_map do
    %{
      # 2 => &handle_awareness/2,
      3 => &handle_ping/2,
      4 => &handle_compose/2,
      6 => &handle_message/2,
      7 => &handle_commit_offset/2,
    }
  end

  defp default_handler(%{eid: eid, device_id: device_id} = state, data) do
    Logger.error("Unknown route received for device #{device_id}, eid #{eid}")
    {:ok, state}
  end

  def websocket_info(:send_ping, state) do
    IO.inspect(1)
    {:reply, :ping, state}
  end

  def websocket_handle(:pong,  state) do
    IO.inspect(2)
    case Connect.client_server_inbound({:device_id, state.device_id, :pong, DateTime.utc_now()}) do
      :ok ->
        {:ok, state}
      :error ->
        :ok
    end
  end

  defp handle_ping(state, data) do
    case Connect.client_server_inbound({:device_id, state.device_id, :ping, data}) do
      :ok ->
        {:ok, state}
      :error ->
        reason = "Field '' →  Invalid ping 500"
        throws = ThrowProtocolErrorSchema.build(@ping_route_id, reason, Until.UniPosTime.response_time())
        send(self(), {:binary, throws})
    end
  end

  defp handle_message(state, data) do
    case Connect.client_server_inbound({:device_id, state.device_id, :message, data}) do
      :ok ->
        {:ok, state}
      :error ->
        reason = "Field '' → #{} Invalid message 500"
        throws = ThrowProtocolErrorSchema.build( @message_route_id, reason, Until.UniPosTime.response_time())
        send(self(), {:binary, throws})
    end
  end

  defp handle_compose(state, data) do
    case Connect.client_server_inbound({:device_id, state.device_id, :compose, data}) do
      :ok ->
        {:ok, state}
      :error ->
        {:ok, state}
    end
  end

  defp handle_commit_offset(state, data) do
    case Connect.client_server_inbound({:device_id, state.device_id, :offset_commit, data}) do
      :ok ->
        {:ok, state}
      :error ->
        reason = "Field '' → Invalid commmit offset 500"
        throws = ThrowProtocolErrorSchema.build(@commit_offset_route_id, reason, Until.UniPosTime.response_time())
        send(self(), {:binary, throws})
        {:ok, state}
    end
  end

  # defp handle_logout(state, data) do
  #   IO.inspect("log_out_route")
  #   case RegistryHub.route_same_ping(state.eid, state.device_id, data) do
  #     :ok -> {:ok, state}
  #     :error ->

  #     error_msg =
  #     ThrowErrorScheme.error(503, "Service temporarily unavailable", 10)

  #     send(self(), {:binary, error_msg})
  #     {:ok, state}
  #   end
  # end

  def websocket_info(:terminate_socket, state) do
    {:stop, state}
  end

  # -----------------------
  # Only decode the route field for fast dispatch
  # -----------------------
  defp safe_decode_route(data) do
    try do
      with %Bimip.MessageScheme{route_id: route} <- Bimip.MessageScheme.decode(data) do
        {:ok, route}
      else
        _ -> {:error, :invalid_route}
      end
    rescue
      e -> {:error, e}
    end
  end

  # terminate, send offline message.......
  def terminate(reason, _req, state) do
    Connect.handle_terminate(reason, state)
    :ok
  end
end
