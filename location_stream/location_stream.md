# bimIPs Protocol: GPS Hardware Integration Guide
**Version:** 1.0.2  
**Status:** Production  
**Transport:** WebSocket (Binary)  
**Serialization:** Protocol Buffers (Protobuf 3)

---

## 1. Connection Overview
The **bimIPs** gateway requires a persistent, bidirectional WebSocket connection. All telemetry data is streamed as binary frames using the provided `.proto` schema.

### Gateway Details
* **Endpoint:** `ws://wsone.com:4000`
* **Mode:** Binary (Opcode 0x2)

### Connection Headers
The following headers must be provided during the WebSocket handshake. Connections will be rejected if headers are missing or invalid.

| Header Key | Type | Value | Description |
| :--- | :--- | :--- | :--- |
| `token` | `String` | `Bearer <JWT_TOKEN>` | Unique device/session access token. |
| `type` | `String` | `1` | Must be "1" for GPS hardware classification. |

---

## 2. Heartbeat & Connection Stability
The server maintains connection health using standard WebSocket **Control Frames**.

* **Protocol-Level Ping (Opcode 0x9):** The server sends a low-level Ping to the device.
* **Automatic Response:** The device **must** respond with a Pong (Opcode 0xA) immediately.
* **Recommended Library:** We recommend **[IXWebSocket](https://github.com/machinezone/IXWebSocket)** (C++). It handles these protocol-level Pings in the background automatically, preventing timeouts on cellular networks (2G/4G/5G).

---

## 3. Protocol Schema (`bimip.proto`)
Hardware must compile this schema to generate communication headers. All telemetry data is encapsulated in the `MessageScheme` wrapper using `route_id: 9`.

```protobuf
syntax = "proto3";

package bimip;

message Identity {
  string eid = 1; 
  optional string connection_resource_id = 2;
  optional string node = 3;
}

message LocationStream {
  Identity from = 1;
  Identity to = 2;
  double latitude = 3;
  double longitude = 4;
  optional double altitude = 5;
  int64 timestamp = 6;
}

message Ping {
  string id = 1;
  Identity from = 2;
  int32 type = 3; // 1: Ping, 2: Pong
  int64 timestamp = 4;
}

message MessageScheme {
  int64 route_id = 1;
  oneof payload {
    Ping ping = 3;
    LocationStream location_stream = 9;
    // ... other stanzas omitted for brevity
  }
}
```

---

## 4. C++ Implementation Reference

### A. Constructing the Location Packet
```cpp
#include "bimip.pb.h"
#include <chrono>

std::string createLocationPacket(double lat, double lon, std::string deviceEid) {
    bimip::MessageScheme scheme;
    scheme.set_route_id(9); // Route 9 = LocationStream

    auto* stream = scheme.mutable_location_stream();
    stream->mutable_from()->set_eid(deviceEid);
    stream->mutable_to()->set_eid("server@bimips.dev"); // Gateway target
    
    stream->set_latitude(lat);
    stream->set_longitude(lon);
    
    // Set timestamp in UTC milliseconds
    auto ms = std::chrono::duration_cast<std::chrono::milliseconds>(
        std::chrono::system_clock::now().time_since_epoch()).count();
    stream->set_timestamp(ms);

    std::string buffer;
    scheme.SerializeToString(&buffer);
    return buffer;
}
```

### B. Connection Logic (IXWebSocket)
```cpp
#include <ixwebsocket/IXWebSocket.h>

void connectTracker() {
    ix::WebSocket webSocket;
    webSocket.setUrl("ws://wsone.com:4000");

    // Set Handshake Headers
    ix::WebSocketHttpHeaders headers;
    headers["token"] = "Bearer <YOUR_TOKEN>";
    headers["type"] = "1";
    webSocket.setExtraHeaders(headers);

    // Protocol-level pings are handled automatically by IXWebSocket
    webSocket.setOnMessageCallback([&webSocket](const ix::WebSocketMessagePtr& msg) {
        if (msg->type == ix::WebSocketMessageType::Open) {
            std::cout << "bimIPs Connected" << std::endl;
        } 
        else if (msg->type == ix::WebSocketMessageType::Message && msg->binary) {
            // Handle binary server commands (Route 6, etc.)
            bimip::MessageScheme incoming;
            if (incoming.ParseFromString(msg->str)) {
                // Process incoming server logic
            }
        }
    });

    webSocket.start();
}
```

---

## 5. Technical Requirements
* **Coordinate Precision:** `latitude` and `longitude` fields are **double** (64-bit). Using 32-bit floats will cause inaccurate mapping.
* **Binary Framing:** All data must be sent as a **WebSocket Binary Frame**. Text frames are unsupported.
* **Backoff Strategy:** On disconnection, hardware should use exponential backoff (1s, 2s, 4s... up to 60s) to reconnect.
* **Time:** All `timestamp` fields must be **Unix Milliseconds (UTC)**.

