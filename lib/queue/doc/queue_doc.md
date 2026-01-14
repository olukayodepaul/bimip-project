# Bimip Queue System – Comprehensive Technical Documentation

## 1. Overview

The **Bimip Queue System** is a high‑throughput, append‑only, sharded message persistence engine designed for large‑scale, real‑time systems (chat, event streaming, device sync). It is inspired by log‑structured storage systems (Kafka‑like) but implemented natively on the BEAM using **GenServer, ETS, and raw disk I/O**.

Key goals:

* Horizontal scalability via sharding
* Sequential disk writes for durability
* Zero‑lock hot paths
* Crash‑safe recovery
* Exactly‑once message protection
* Efficient disk compaction

---

## 2. Core Concepts

### 2.1 Shards

* The system uses **64 shards**.
* Each shard is an independent GenServer managing its own log segment files.
* Shard selection is deterministic:

```
shard = phash2(user, 64)
```

This ensures:

* Per‑user message ordering
* Even load distribution
* Failure isolation

---

### 2.2 Segments

A **segment** is a pair of files:

* `.log` – append‑only binary message storage
* `.idx` – sparse index mapping `(user, partition, offset) -> file position`

Each shard always has:

* **One active segment** (currently writable)
* **Multiple historical segments** (read‑only)

Segments rotate when they exceed **100MB**.

---

### 2.3 Message Lifecycle

1. Message arrives
2. Deduplication check (`MessageTracker`)
3. Struct normalization (`Queue.Persist`)
4. Buffered write (ETS)
5. Batched flush to disk
6. Indexed for random access
7. Delivered to consumers
8. Eventually compacted

---

## 3. Module‑by‑Module Documentation

---

## 3.1 `Queue.QueueLogImpl`

### Responsibility

The **core storage engine**. Handles:

* Message writes
* Disk persistence
* Reads (hot + cold)
* Segment rotation
* Compaction swaps

### Internal Data Structures

| Structure       | Purpose                      |
| --------------- | ---------------------------- |
| ETS buffer      | Hot write buffer             |
| ETS index cache | Offset → file lookup         |
| Manifest file   | Tracks active segment        |
| Reader FD pool  | Limits open file descriptors |

---

### Write Path

**Step 1 – Buffering**

* Messages are inserted into ETS (`duplicate_bag`).
* Backpressure enforced via buffer size limit.

**Step 2 – Flush Loop**

* Runs every 100ms.
* Flushes buffered messages sequentially.
* Writes:

  * Binary payload to `.log`
  * Index entry to `.idx`

**Step 3 – Durability**

* `datasync/1` is called on both files.

---

### Read Path

Reads are attempted in this order:

1. **Hot buffer (ETS)** – ultra‑low latency
2. **Index cache (ETS)** – resolves file + position
3. **Disk read** – CRC validated payload

A **reader pool** caches file descriptors using an LRU strategy to avoid OS FD exhaustion.

---

### Segment Rotation

When active segment exceeds `@max_segment_size`:

1. Files are closed
2. New segment base ID generated
3. Manifest updated
4. New segment opened atomically

No write interruption occurs.

---

### Compaction Swap

Triggered externally by `BimipCompactor`:

* Index cache updated with new positions
* Reader pool cleaned
* Old files deleted

Active segments are protected from compaction.

---

## 3.2 `Queue.BimipCompactor`

### Responsibility

Background lifecycle manager that:

* Enforces retention (TTL)
* Merges historical segments
* Reduces disk usage

---

### Compaction Flow

1. Periodic scan (every 60s)
2. Identify historical segments
3. Stream index entries
4. Retain only records newer than TTL
5. Write merged segment
6. Atomically swap via shard GenServer

---

### Safety Guarantees

* Source files opened once
* No in‑place mutation
* Atomic rename
* Shard‑controlled deletion

Crash‑safe by design.

---

## 3.3 `Queue.MessageTracker`

### Responsibility

Provides **exactly‑once message protection** using in‑memory tracking.

---

### Design

* Two‑generation ETS tables
* 256 partitions per generation
* Zero‑lock hot path

Generation switching allows instant cleanup without blocking writers.

---

### Check Algorithm

1. Hash message key
2. Check old generation
3. Check current generation
4. Insert if absent or expired

TTL enforced per message.

---

## 3.4 `Queue.MessageTracker.Sweeper`

### Responsibility

Time‑based orchestration:

* Periodic TTL sweep (optional)
* Generation rotation every 12h

Rotation clears stale data without latency spikes.

---

## 3.5 `Queue.DeviceBookmark`

### Responsibility

Tracks **per‑device consumption offsets**.

---

### Architecture

* Sharded Mnesia tables (durable)
* Sharded ETS caches (hot reads)

Offsets are monotonic and idempotent.

---

### Failure Model

* ETS loss → recovered from Mnesia
* Worst case: duplicate delivery (safe)

---

## 3.6 `Queue.Persist`

### Responsibility

Pure data normalization layer.

* Builds `%Bimip.Message{}` structs
* Ensures consistent on‑disk schema
* Attaches writer metadata for filtering

No side effects.

---

## 4. System Guarantees

| Guarantee          | Level        |
| ------------------ | ------------ |
| Ordering           | Per user     |
| Durability         | fsync        |
| Deduplication      | Exactly‑once |
| Backpressure       | Yes          |
| Crash recovery     | Strong       |
| Horizontal scaling | Yes          |

---

## 5. Failure Scenarios & Handling

* **Shard crash** → isolated, supervisor restarts
* **Disk corruption** → CRC detection
* **FD exhaustion** → LRU eviction
* **Compaction crash** → old segments remain intact

---

## 6. Operational Notes

Recommended monitoring:

* ETS table sizes
* Segment counts per shard
* Reader pool usage
* Compaction duration

---

## 7. Mental Model Summary

Think of the system as:

> **“64 independent append‑only logs with intelligent memory front‑buffers, a rotating identity ledger, and a garbage collector that never blocks production traffic.”**

---

## 8. Conclusion

This queue system is production‑grade and suitable for:

* Real‑time messaging
* Event sourcing
* Device synchronization
* Financial or audit logs

It favors **correctness, durability, and throughput** over unnecessary abstraction.

---

*End of documentation.*
