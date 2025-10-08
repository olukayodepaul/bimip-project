add Scheme for Awareness change.

```
message AwarenessRequest {
  Identity from = 1;
  Identity to = 2;
  int64 awareness_identifier = 3;  // Unique request ID
  int64 timestamp = 4;
}

message AwarenessResponse {
  Identity from = 1;
  Identity to = 2;
  string awareness_identifier = 3;
  int32 status = 4;                 // 1=ONLINE, 2=OFFLINE, 3=AWAY, 4=BUSY, 5=DO_NOT_DISTURB, 6=INVISIBLE, 7=IDLE, 8=UNKNOWN
  double latitude = 5;
  double longitude = 6;
  int32 awareness_intention = 7;
  int64 timestamp = 8;
}


//messaging protoco
// ---------------- Payloads ----------------
message TextPayloadRequest {
  Identity from           = 1;
  repeated Identity to    = 2;
  string content          = 3;
  string message_id_local = 4;
  string text_size_count  = 5;
  int64 created_at        = 6;

  // Optional fields for media attachments
  string cdn_url_id       = 7;  // client-generated resource ID for image/file
  int64 media_size_bytes  = 8;  // size of the media if attached
}


//using grpc for images on cdn servers. send to cdn server to upload image and return with thumbnail_url
//note, generate the thumbnail_url from client.
message MediaPayloadRequest {
  Identity from           = 1;
  repeated Identity to    = 2;
  string message_id_local = 3;
  string chat_id          = 4;
  int32  type             = 5;  // 1=image | 2=audio | 3=video | 4=file
  string caption          = 6;
  string cdn_url_id       = 8;
  int64 media_size_bytes  = 9;
  int64 created_at        = 10;
}

def generate_image_resource_id(username, device_id) do
  timestamp = DateTime.utc_now() |> DateTime.to_unix(:millisecond)
  random_hash = :crypto.strong_rand_bytes(6) |> Base.url_encode64(padding: false)
  "#{username}-#{device_id}-#{timestamp}-#{random_hash}"
end


// ---------------- Acknowledgment ----------------
// 1. Receiver send acknowledgment to senders
// 2. Sender acknowledge receive base of the status
message AcknowledgmentRequest{
  Identity from     = 1;       // receiving client
  Identity to       = 2;       // original sender
  string message_id = 3;
  int32  status     = 4;       // Sender ( 1 = unread | 2 = delivered | 3=read ) || Reciever ( 4 = sent | 2 = delivered | 3 = read )
  int64  timestamp  = 5;
}

message AcknowledgmentResponse{
  Identity from     = 1;    // receiving client
  Identity to       = 2;    // original sender
  string message_id = 3;
  int32  status     = 4;    // Sender ( 1 = unread | 2 = delivered | 3=read ) || Reciever ( 4 = sent | 2 = delivered | 3 = read )
  int64  timestamp  = 5;
}

// ---------------- ChatMessage ----------------
// sender keep a version of this
// server send a version of this to recervers.
message ChatMessage {
  Identity from           = 5;
  repeated Identity to    = 6;
  string message_id       = 1;  // server-assigned global ID
  string message_id_local = 2;  // client temporary ID
  int64  version          = 3;  // server-assigned chat sequence
  string chat_id          = 4;  // conversation ID
  string ownership        = 5;  // 1 = sender, 2 = receiver

  oneof payload {
    string  text  = 7;
    string media_url = 8; //cnd links
  }

  string acknowledgment =  9; // update acknowledgment status
  string  acknowledgment_timestamp =  10; // update acknowledgment timestamp

  int64 created_at         = 9;
  int64 server_received_at = 10;

}


message MessageScheme {
  int64 route = 1;

  oneof payload {
    AwarenessNotification awareness_notification = 2;
    AwarenessResponse awareness_response = 3;
    AwarenessRequest awareness_request = 4;


    TokenRevokeRequest token_revoke_request = 7;
    TokenRevokeResponse token_revoke_response = 8;
    SubscriberAddRequest subscriber_add_request = 9;

    Logout logout = 12;
    TextPayloadRequest text_payload_request = 13
    MediaPayloadRequest media_payload_request = 14;
  }
}




```

```
AwarenessNotification awareness_notification  = 1;  // User awareness/presence update
AwarenessResponse awareness_response          = 2;
AwarenessRequest awareness_request            = 3;
PingPong ping_pong                            = 4;
TokenRevokeRequest token_revoke_request       = 5;
TokenRevokeResponse token_revoke_response     = 6;
SubscribeRequest subscribe_request            = 7;
SubscribeResponse subscribe_response          = 8;
UnsubscribeRequest unsubscribe_request        = 9;
UnsubscribeResponse unsubscribe_response      = 10;
Logout logout                                 = 11; // Logout message
ErrorMessage error                            = 12; // Error message
```

logout

```proto
logout = %Bimip.Logout{
  to: %Bimip.Identity{
    eid: "a@domain.com",
    connection_resource_id: "aaaaa1",
  },
  type: 1,
  status: 4,
  timestamp: System.system_time(:millisecond)
}

is_logout = %Bimip.MessageScheme{
  route: 10,
  payload: {:logout, logout}
}

binary = Bimip.MessageScheme.encode(is_logout)
hex    = Base.encode16(binary, case: :upper)

```

error

```proto
// ---------------- PingPong ----------------
// Heartbeat messages from client to server to check connectivity of a specific device (Identity includes both eid and connection_resource_id)
// Client generates ping_id; server echoes it back in PONG with pong_time
message PingPong {
  Identity from = 1;              // Sender's identity (user or device)
  Identity to = 2;                // Optional: target identity (used if resource = OTHERS)
  int32 resource = 3;             // 1=SAME (server ping), 2=OTHERS (user-to-user ping)
  int32 type = 4;                 // 1=PING, 2=PONG
  int64 ping_time = 5;            // Unix UTC timestamp (ms)
  int64 pong_time = 6;            // Unix UTC timestamp (ms)
}



message PingPong {
  Identity from = 1;              // Sender's identity (user or device)
  Identity to = 2;                // Optional: target identity (used if resource = OTHERS)
  int32 resource = 3;             // 1=SAME (server ping), 2=OTHERS (user-to-user ping)
  int32 type = 4;                 // 1=PING, 2=PONG
  int64 ping_time = 5;            // Unix UTC timestamp (ms)
  int64 pong_time = 6;            // Unix UTC timestamp (ms)
}


logout = %Bimip.PingPong {
  from: %Bimip.Identity{
    eid: "a@domain.com",
    connection_resource_id: "aaaaa1",
  },
  to: %Bimip.Identity{
    eid: "b@domain.com",
    connection_resource_id: "bbbbb1",
  },
  resource: 2,
  type: 1,
  ping_time: System.system_time(:millisecond),
  pong_time: System.system_time(:millisecond)
}
is_logout = %Bimip.MessageScheme{
  route: 3,
  payload: {:ping_pong, logout}
}

binary = Bimip.MessageScheme.encode(is_logout)
hex    = Base.encode16(binary, case: :upper)


```

defp handle_ping_request(
%Bimip.PingPong{resource: resource, ping_time: ping_time},
%{ws_pid: ws_pid, eid: eid, device_id: device_id} = state
) do
case resource do
1 ->
case RegistryHub.request_cross_server_online_state(eid) do
:ok ->
pong = ThrowPingPongSchema.same(eid, device_id, ping_time)
send(ws_pid, {:binary, pong})
{:noreply, state}

          :error ->
            reply_and_close(ws_pid, ThrowErrorScheme.error(404, "Service Unavailable", 3))
            {:noreply, state}
        end

      2 ->
        # Resource 2: user-to-user ping (currently no-op here)
        {:noreply, state}

      _ ->
        # Invalid resource
        reply_and_close(ws_pid, ThrowErrorScheme.error(401, "Invalid Resource ID", 3))
        {:noreply, state}
    end

end
