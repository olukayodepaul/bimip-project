## **1. Getting Started**

### **1.1 Introduction**

#### What is Bimip?

**Bimip (Binary Interface for Messaging and Internet Protocol)** is a next-generation real-time communication protocol built for **speed, scalability, and reliability** across distributed systems.  
It introduces a **binary message structure** defined through schema-based stanzas that optimize data transfer between clients and servers.

Bimip enables **event-driven**, **state-aware**, and **low-latency communication** suitable for cloud, IoT, mobile, and enterprise platforms where efficiency and awareness are crucial.

---

### **Why Bimip?**

Traditional text-based messaging systems often face challenges such as bandwidth overhead, parsing complexity, and limited extensibility under high-frequency operations.

**Bimip** solves these problems through its **binary messaging architecture**, leveraging schema definitions (via **Protocol Buffers**) to achieve:

- Compact and efficient message encoding
- Backward and forward compatibility
- Low-latency data transmission
- Consistent schema evolution

Key advantages of Bimip:

- ⚡ **Binary efficiency** – lower latency and reduced bandwidth usage
- 🧠 **Awareness-oriented communication** – supports user, system, and location states
- 🧩 **Extensible schema** – add new stanza types without breaking compatibility
- 🌍 **Cross-language SDKs** – Elixir, Swift, Kotlin, and Node.js integrations
- 📊 **Built-in observability** – metrics, ping-pong health checks, and activity monitoring

---

### **What can I use Bimip for?**

Bimip supports a broad range of real-time distributed communication use cases:

- 💬 **Instant messaging and collaboration**
- 🌐 **IoT synchronization** and device telemetry
- 💳 **Financial transactions and payment systems**
- 🎮 **Gaming platforms** with live player awareness
- 📡 **Monitoring and telemetry pipelines**
- 👥 **Presence and state tracking across distributed environments**

---

### **How Bimip Works (In a Nutshell)**

Bimip structures communication using **binary stanzas**, encoded with **Protocol Buffers**, and exchanged through two primary connection types:

- **Native TCP Connections** — persistent, low-latency binary streams between servers and backend services
- **WebSocket Connections** — real-time communication with browser and mobile clients

Each connection type supports **bidirectional messaging**, session persistence, and awareness synchronization.  
Each stanza represents a specific function — such as:

```

Identity, Awareness, PingPong, Message, TokenRevoke, TokenRefresh, SubscribeAwareness, UnsubscribeAwareness

```

Bimip uses a **client–server architecture**, where device and server processes are managed through the **ESM Epochai session manager** built into the system orchestrator.  
The server leverages **lightweight Elixir processes**, **OPT**, and **distributed storage mechanisms** to ensure scalable and fault-tolerant communication across nodes.

<img src="Screenshot 2025-10-09 at 19.18.14.png" alt="diagram">

| Component           | Description                                                                 |
| ------------------- | --------------------------------------------------------------------------- |
| **Client**          | Publishes and receives stanzas, manages session state, and tracks awareness |
| **Server**          | Routes messages, authenticates identities, and synchronizes awareness data  |
| **Registry**        | Maintains active user sessions across distributed nodes                     |
| **Awareness Layer** | Manages user, system, and location states in real time                      |

---

## **2. Main Concepts and Terminology**

| Term           | Meaning                                                                        |
| -------------- | ------------------------------------------------------------------------------ |
| **Stanza**     | A discrete, typed message unit defining communication semantics                |
| **Identity**   | Represents a user, device, or service identified by a unique EID (Entity ID)   |
| **Awareness**  | Real-time representation of a user’s or system’s state                         |
| **PingPong**   | Lightweight heartbeat for connection health and latency measurement            |
| **Session**    | Active link between a client and the Bimip server, managed via in-memory state |
| **StanzaType** | Identifier describing the purpose or category of a message                     |

---

## **3. Architecture Overview**

Bimip operates as a **distributed Elixir application** optimized for **multi-node communication**, **high throughput**, and **minimal latency**.

### **Core Components**

- **Session Manager:** Manages per-user state, message routing, and lifecycle of device processes
- **In-Memory Storage:** Combines high-speed lookup tables for active client sessions with a **file system–backed persistence layer**. Data is organized using **partitioned categories with offset tracking**, enabling replay, recovery, and scalable message retention

  #### Queue Files Overview

  Bimip uses **two files** to manage queued messages efficiently:

  1. **Queue File**

     - Stores all message data in-memory and persisted to disk
     - Uses a **composite key**: `(EID, increment_id)` to uniquely identify each message
     - Ensures fast retrieval of individual messages and maintains ordering per entity
     - Supports **replay and recovery** after server restarts

  2. **Queue Index File**
     - Maintains **metadata for quick access**:
       - **EID** as a composite key
       - **last_offset**: points to the last read/processed message
       - **last_increment**: tracks the last inserted message ID
     - Enables **O(1) lookup** of the latest message per entity without scanning the entire queue
     - Works with the file-backed Queue File to quickly locate messages on disk

  #### Workflow

  - When a new message is enqueued, the **Queue Files** store the full data, and the **Queue Index Files** update `last_increment` and `last_offset`
  - Consumers can quickly fetch the latest or unprocessed messages using the index files
  - Messages are stored in **partitioned directories or files** based on category, with sequential offsets enabling efficient sequential read/write

- **Awareness Engine:** Synchronizes user, system, and location-level presence across distributed nodes
- **PingPong Monitor:** Performs continuous session validation, latency measurement, and link health checks
- **Broker Layer:** Facilitates publisher–subscriber (Pub–Sub) messaging and event distribution
- **Orchestrator (ESM Epoch Server):** Coordinates process supervision, load distribution, and fault recovery

---

## **4. Bimip APIs**

Bimip provides multiple APIs and SDKs to support diverse integration environments:

| API               | Description                                                                |
| ----------------- | -------------------------------------------------------------------------- |
| **WebSocket API** | Enables real-time stanza exchange between clients and servers              |
| **gRPC API**      | Binary-based communication for backend or service-to-service messaging     |
| **CLI Tool**      | Developer console for managing sessions, inspecting stanzas, and debugging |
| **SDKs**          | Available in Elixir, Swift, and Kotlin for easy client integration         |

---

## **5. Version History**

| Version            | Release Date | Highlights                                                                            |
| ------------------ | ------------ | ------------------------------------------------------------------------------------- |
| **1.0**            | October 2025 | Initial release introducing Awareness, Identity, PingPong, and Offer stanzas          |
| **1.1 (Upcoming)** | Q1 2026      | Refactored CLI, expanded SDKs, improved metrics/logging, and filesystem-based storage |

---

## **6. ⚠️ Warning**

> ⚠️ **Warning**  
> **Bimip 1.0** is the **first official release** of the Binary Interface for Messaging and Internet Protocol  
> Stanza definitions and protocol behavior may evolve in subsequent minor versions (1.1+)  
> **Backward compatibility is not guaranteed** during the stabilization phase

---

## **7. Deprecated Features**

There are currently **no deprecated features** in **Bimip 1.0**  
All stanzas, layers, and subsystems remain **active and supported**  
Future deprecations will be documented here once introduced

| Deprecated Feature | Deprecated Since | Removed In | Replacement / Notes |
| ------------------ | ---------------- | ---------- | ------------------- |
| _None_             | –                | –          | –                   |

---

## **8. Where to Go from Here**

- Review the **Quickstart Guide** to launch your first Bimip node
- Explore **Protocol Buffer Definitions** under `/bimip/protos`
- Learn to manage **Awareness** and **PingPong sessions**
- Join the **Bimip Developer Community** to share ideas and collaborate on SDKs

---

© 2025 **Bimip Project**. All rights reserved.
