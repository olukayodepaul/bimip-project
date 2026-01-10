# Bimip Queue System (BQ)

## Purpose

Bimip Queue System is a **Kafka‑class, log‑structured message engine** optimized for **low‑latency, high‑throughput messaging** on the BEAM. It is designed for realtime delivery (WebSocket/Signal), financial eventing, IoT ingestion, and fan‑out workloads where **predictable latency, append‑only durability, and explicit backpressure** matter more than ad‑hoc querying.

This document explains *what the system is*, *why it exists*, and *how it works*—for engineers and researchers evaluating correctness, performance, and design tradeoffs.

---

## Design Principles

1. **Append‑only logs over tables** — sequential I/O, cheap durability.
2. **Hot path in memory, cold path on disk** — ETS for concurrency; disk for truth.
3. **Bounded work everywhere** — no unbounded scans, no surprise pauses.
4. **Explicit control beats implicit magic** — compaction, TTL, backpressure are first‑class.
5. **Crash safety by construction** — atomic manifests, CRCs, quarantine on failure.

---

## High‑Level Architecture

```
Clients
  │
  ▼
Shard Router (consistent hash)
  │
  ├─▶ Shard 0 (GenServer)
  ├─▶ Shard 1 (GenServer)
  └─▶ Shard N (GenServer)
        │
        ├─ ETS write buffer (hot)
        ├─ Sparse index (ETS)
        ├─ Device checkpoints (ETS)
        └─ Append‑only log + index (disk)

Background Services:
- Segment Compactor
- Message Deduplicator (Generational ETS)
- Sweeper / Rotator
```

---

## Data Model

### Message

Each message is written once and addressed by a **monotonic offset** within a shard:

* `(user, partition_id, offset)`
* Payload is application‑defined
* Stored as compressed Erlang term with CRC

### Offsets

* Per‑partition offsets (writer‑side)
* Per‑device bookmarks (reader‑side)
* Offset monotonicity is enforced

---

## Write Path

1. Client submits message
2. User is hashed → shard
3. Message placed into **ETS buffer**
4. Backpressure applied if buffer exceeds quota
5. Periodic flush writes records sequentially to disk
6. Sparse index updated based on adaptive stride
7. Device checkpoint updated

**Key properties**

* No random writes
* No locks on hot path
* Bounded memory usage

---

## Read Path

1. Lookup in ETS buffer (hot hit)
2. Lookup in sparse index (O(1))
3. If miss, perform **bounded scan** from nearest checkpoint
4. Scan aborts after fixed record limit

**Latency is predictable by design.**

---

## Storage Layout

```
segment_<base>.log   # append‑only records
segment_<base>.idx   # sparse index
manifest.bin         # active base + metadata
```

* Records include CRC and size
* Disk writes are sequential
* Atomic rename used for manifest updates

---

## Compaction & Retention

### Segment Compaction

* Triggered after N segments
* Copies records into new segment
* Updates manifest atomically
* Old segments removed only after success
* Partial failures moved to quarantine

### TTL Retention

* Time‑based retention
* Old segments deleted as a unit
* No per‑record deletes

**This avoids tombstones and vacuum storms.**

---

## Device Bookmarks

* Per‑device, per‑user, per‑partition offsets
* Sharded ETS for concurrency
* Periodic persistence to disk
* Adjusted automatically after compaction

This enables **fan‑out and resumable delivery**.

---

## Message Deduplication

Implemented using **two‑generation ETS tables**:

* Active generation (lock‑free via `persistent_term`)
* Old generation for overlap safety
* TTL‑based expiration
* Periodic rotation with throttled cleanup

Properties:

* O(1) checks
* No global locks
* Handles 50M+ keys

---

## Failure Model & Safety

Handled failures:

* Partial disk writes (CRC + retry)
* Process crashes (append‑only safety)
* Compaction crashes (quarantine)
* Restart recovery via manifest + index rebuild

Not yet handled (V2):

* Node loss
* Network partitions
* Cross‑node replication

---

## Performance Characteristics

| Dimension   | Property                    |
| ----------- | --------------------------- |
| Writes      | Sequential, high throughput |
| Reads       | Bounded latency             |
| TTL         | O(1) segment delete         |
| Memory      | Bounded ETS buffers         |
| Concurrency | Shard‑isolated              |

The system is designed to scale **linearly by shard count**.

---

## Comparison to Existing Systems

### PostgreSQL

* Good for metadata and queries
* Poor fit for high‑churn queues
* Expensive TTL and deletes

### Cassandra

* Distributed, durable
* Tombstone‑heavy for TTL
* Less predictable latency

### Kafka

* Same architectural class
* Bimip focuses on **lower latency and BEAM integration**
* Kafka has broader ecosystem and maturity

---

## Intended Use Cases

* Realtime messaging / signaling
* Notification pipelines
* Financial transaction streams
* IoT ingestion
* Event sourcing

Not intended for:

* Ad‑hoc querying
* Relational joins
* OLAP workloads

---

## Roadmap (V2 Highlights)

* Leader–follower replication
* Multi‑node shard routing
* Snapshots for fast bootstrap
* Consumer groups
* Stronger consistency (fencing, epochs)
* Observability & admin tooling

---

## Summary

Bimip Queue System is a **purpose‑built log engine**, not a database abstraction. Its design choices favor **correctness, predictability, and throughput** over generality. V1 establishes a solid single‑node foundation; V2 extends it into a fully distributed, Kafka‑class system.

The core architecture is intentionally simple, explicit, and analyzable—making it suitable for both production use and academic discussion.
