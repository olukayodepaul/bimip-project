```awarenesss request

# Create the AwarenessRequest message
request = %Dartmessaging.AwarenessRequest{
  from: %Dartmessaging.Identity{ eid: "a@domain.com" },
  to: %Dartmessaging.Identity{ eid: "b@domain.com" },
  awareness_identifier: System.system_time(:millisecond),
  timestamp: 0
}


# Wrap in MessageScheme
msg_request = %Dartmessaging.MessageScheme{
  route: 4,  # Logical route for awareness_request
  payload: {:awareness_request, request}
}

# Encode to binary for WebSocket
binary_request = Dartmessaging.MessageScheme.encode(msg_request)

# You can now send `binary_request` to your WebSocket
hex = Base.encode16(binary_request, case: :upper)
080422270A0E0A0C6140646F6D61696E2E636F6D120E0A0C6240646F6D61696E2E636F6D18B59EA8E29033


```

```
ping pong


ping_request = %Dartmessaging.PingPong{
  from: %Dartmessaging.Identity{ eid: "a@domain.com",  connection_resource_id  },
  to: %Dartmessaging.Identity{ eid: "b@domain.com" },
  status: 1,                   # 1 = PENDING
  request_time: System.system_time(:millisecond),
  response_time: 0
}

# Wrap in MessageScheme
msg_ping = %Dartmessaging.MessageScheme{
  route: 6,
  payload: {:pingpong_message, ping_request}
}

# Encode to binary
binary_request = Dartmessaging.MessageScheme.encode(msg_ping)

# Optional: hex for debugging
hex_ping = Base.encode16(binary_request, case: :upper)
080632290A0E0A0C6140646F6D61696E2E636F6D120E0A0C6240646F6D61696E2E636F6D200128BBA5A3E29033

```

```

token_revoke_request = %Dartmessaging.TokenRevokeRequest{
  to: %Dartmessaging.Identity{
    eid: "b@domain.com",
    connection_resource_id: "bbbbb1"
  },
  token: "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9...",  # raw JWT
  timestamp: System.system_time(:millisecond)
}

# Wrap in MessageScheme
msg_request = %Dartmessaging.MessageScheme{
  route: 7,  # Logical route for TokenRevokeRequest
  payload: {:token_revoke_request, token_revoke_request}
}

# Encode to binary for WebSocket
binary_request = Dartmessaging.MessageScheme.encode(msg_request)

# Optional: convert to hex for debugging/logging
hex_request = Base.encode16(binary_request, case: :upper)

IO.inspect(hex_request, label: "TokenRevokeRequest (hex)")

080632290A0E0A0C6140646F6D61696E2E636F6D120E0A0C6240646F6D61696E2E636F6D200128BBA5A3E29033
```

```logout


logout = %Bimip.Logout{
  to: %Bimip.Identity{
    eid: "a@domain.com",
    connection_resource_id: "aaaaa1",
  },
  type: 1,
  status: 4,
  timestamp: System.system_time(:millisecond)
}

# Wrap in MessageScheme
is_logout = %Bimip.MessageScheme{
  route: 12,
  payload: {:logout, logout}
}



binary = Bimip.MessageScheme.encode(is_logout)
hex    = Base.encode16(binary, case: :upper)

080C62230A160A0C6140646F6D61696E2E636F6D12066161616161311001180420EAB48B9E9233
```

```ping_pong

ping_pong = %Bimip.PingPong{
  to: %Bimip.Identity{
    eid: "a@domain.com",
    connection_resource_id: "aaaaa1"
  },
  type: 1,
  ping_time: System.system_time(:millisecond),
  ping_id: "ergfyerhfjerhgueggdgr"
}

# Wrap in MessageScheme
is_ping_pong = %Bimip.MessageScheme{
  route: 6,  # Logical route for TokenRevokeRequest
  payload: {:ping_pong, ping_pong}
}

binary = Bimip.MessageScheme.encode(is_ping_pong)
hex    = Base.encode16(binary, case: :upper)

080632340A160A0C6140646F6D61696E2E636F6D1206616161616131100118F1BB94A191332A116572676679657268666A65726867756572
```

message Logout {
Identity to = 1; // The user/device performing logout
int32 type = 2; // 1 = REQUEST, 2 = RESPONSE
int32 status = 3; // 1 = DISCONNECT, 2 = FAIL, 3 = SUCCESS, 4 = PENDING
int64 timestamp = 4; // Unix UTC timestamp (ms) of the action
}

// ---------------- MessageScheme ----------------
// Wrapper for all messaging protocol types
message MessageScheme {
int64 route = 1; // Unique route identifier for message routing

oneof payload {
AwarenessNotification awareness_notification = 2; // User awareness/presence update
PingPong ping_pong = 6;
Logout logout = 12; // Logout message
ErrorMessage error = 15; // Error message
}
}

```token revoke

message TokenRevokeRequest {
  Identity to = 1;
  string token = 2;
  int64 timestamp = 3;
}

message TokenRevokeResponse {
  Identity to = 1;
  int32 status = 2;       // 1=SUCCESS, 2=FAILED
  int64 timestamp = 3;
  string reason = 4;      // optional: provides explanation if status=FAILED
}

token_revoke = %Bimip.TokenRevokeRequest{
  to: %Bimip.Identity{
    eid: "a@domain.com",
    connection_resource_id: "aaaaa1"
  },
  token: "eyJhbGciOiJSUzI1NiIsInR5cCI6IkpXVCJ9.eyJhdWQiOiJKb2tlbiIsImRldmljZV9pZCI6ImFhYWFhMSIsImVpZCI6ImFAZG9tYWluLmNvbSIsImV4cCI6MTc1NzM1MzQ2NCwiaWF0IjoxNzU3MjY3MDY0LCJpc3MiOiJKb2tlbiIsImp0aSI6IjMxaGgyNWRoMDNlbXQ5NGtlNDAwMDI2MSIsIm5iZiI6MTc1NzI2NzA2NCwidHlwZSI6ImFjY2VzcyIsInVzZXJfaWQiOiIxIn0.ql177KGZsehJSMqifXkpjdKHhe7IclrupQ2Pb5xxuSwbSZ4z7akHtBMZjIbSUikVc8g68Zivmi6RYtSrBEdyTzZJzb6hhCBqnI-Wy6UM_A037JKOnArBZKdGA5uD1ASPTS_QPGirxJihOFdYmTIjSjUkmSa5OHGv0l_Tks7DiB8JSTXtGjtIgrnlkdfmUADOhZK-4tKrsdLK9p7aUvhBweUpI-9XN8RmuO7NiAOBcCpRguqK7N0-PaQIDHmKnxVTlwB90hZI_MAyrcMiBzQ50DRJ39Hhsr5tV_lpSjVO_e9sbbp-g2B4v67fol7Ie6wr75zuB3L5BEmRs2i6Q5UJQg",
  timestamp: System.system_time(:millisecond),
  reason: "Application development"
}

# Wrap in MessageScheme
is_token_revoke = %Bimip.MessageScheme{
  route: 7,
  payload: {:token_revoke_request, token_revoke}
}

binary = Bimip.MessageScheme.encode(is_token_revoke)
hex    = Base.encode16(binary, case: :upper)

08073AAE050A160A0C6140646F6D61696E2E636F6D120661616161613112F30465794A68624763694F694A53557A49314E694973496E523563434936496B705856434A392E65794A68645751694F694A4B6232746C62694973496D526C646D6C6A5A5639705A434936496D4E6A59324E6A4D694973496D56705A434936496D4E415A47397459576C754C6D4E7662534973496D5634634349364D5463314E7A4D304E7A4D324E79776961574630496A6F784E7A55334D6A59774F5459334C434A7063334D694F694A4B6232746C62694973496D703061534936496A4D78614764754D6D64735A6E49334D5759354E47746C4E4441774D4449794D534973496D35695A6949364D5463314E7A49324D446B324E79776964486C775A534936496D466A5932567A63794973496E567A5A584A66615751694F694978496E302E64667153456F5647506E6A75654569704744536D6B366156716D30734E2D3965614D6E6C595A56434D6759534C736C4D7637303553716F36416B784735595451757A47485473463145434C6E5F6C424B55764B3134347974664261716B6375366D7447455A327447696A5F6F753130436F44646A422D6D2D65684F4B61746D515F3777427A5246314E6B4151334B6B3368692D78336F346664455748796C38444F454C624238567A7264624367657A6D36386A765F33756F576E34674F75734E4A76424D7A37426E7737454373467437444A7454595035326A4A64742D32676B52747A53674D4432656B36316E676B6B4C313452415A6757504F574C52386C476A6833366B6670667049743742514B367570524D7466596E51444143595448714E394C4242327557565544786152525F526835736B6C6B336C6F385463516F30463777385871756875467573746F364E65476F636A51188A8CCBA9923322174170706C69636174696F6E20646576656C6F706D656E74
```

```SubscribeRequest


subscribe_request = %Bimip.SubscribeResponse{
  from: %Bimip.Identity{
    eid: "d@domain.com",
    connection_resource_id: nil
  },
  to: %Bimip.Identity{
    eid: "a@domain.com",
    connection_resource_id: nil
  },
  status: 1,
  message: "user information",
  subscription_id: "ancisdcsad",
  one_way: false,
  timestamp: System.system_time(:millisecond)
}

# Wrap in MessageScheme
is_subscribe_request = %Bimip.MessageScheme{
  route: 7,
  payload: {:subscribe_response, subscribe_request}
}

binary = Bimip.MessageScheme.encode(is_subscribe_request)
hex    = Base.encode16(binary, case: :upper)

080632330A0E0A0C6140646F6D61696E2E636F6D120E0A0C6240646F6D61696E2E636F6D1A0A616E636973646373616428CBCBCED49233


```
