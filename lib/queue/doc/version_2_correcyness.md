Perfect. Here’s a **fully polished, integrated V2 design doc** with the WAL section embedded, ready to drop into your repo or share with engineers/scientists. I preserved clarity, system-level rigor, and your accessible analogies.

---

# **Bimip Queue System – Version 2 Design Document**

## **Overview**

Bimip Queue is a **high-throughput, sharded, low-latency messaging system** designed for millions of users per shard. Version 1 (V1) prioritizes **in-memory speed with asynchronous disk flushes**.

Version 2 (V2) introduces **durability, replication, and multi-node scaling**, bringing the system closer to enterprise-grade message brokers like Kafka and Redpanda.

---

## **1. Replication & Fault Tolerance (Highest Priority)**

### Current V1 limitations

* Single copy of data per shard
* Node failure → data unavailable
* No leader/follower coordination

### V2 improvements

* **Leader–Follower replication per shard**
* **Write-ahead replication:** leader writes → followers acknowledge
* ISR (in-sync replicas) tracking
* Configurable **ack levels**:

  * `ack=1` (leader only)
  * `ack=quorum`
* Automatic follower catch-up via segment copy or index rebuild
* Detect and fence stale leaders

📌 *Outcome:* Multi-node safety and zero split-brain scenarios.

---

## **2. Multi-Node Sharding & Routing**

### Current V1 limitations

* Shards local only
* Manual shard-to-node mapping

### V2 improvements

* **Shard map service** `{shard_id → node}`
* Consistent hashing for user → shard mapping
* Node discovery (static or gossip)
* Automatic shard reassignment on node failure
* Graceful shard migration with drain + replay

📌 *Outcome:* True horizontal scalability.

---

## **3. Durable Metadata & Recovery**

### Current V1 limitations

* Manifest only tracks active base
* Limited restart introspection
* Messages acknowledged after ETS write → potential loss on crash

### V2 improvements

#### **3a. Write-Ahead Log (WAL) for Zero-Loss Durability**

* Messages appended to `wal.log` **before** acknowledgment
* ETS updated simultaneously for low-latency access
* Only ACK clients after WAL write succeeds
* Background flush merges WAL into segment files
* WAL truncated after safe segment flush

**Crash recovery flow:**

1. On restart, read `wal.log`
2. Replay missing messages into segments and ETS
3. Rebuild device bookmarks and sparse indices

**Benefit:** No messages lost, decoupling durability from disk-write latency.

#### Other metadata improvements

* Shard metadata file tracks:

  * Current leader
  * Last committed offset
  * Last replicated offset
* Startup recovery phases:

  1. Detect partial segments
  2. Verify CRCs
  3. Rebuild sparse index
  4. Reconcile device bookmarks

📌 *Outcome:* Faster, safer cold restarts with zero data loss.

---

## **4. Snapshotting & Fast Bootstrap**

### Limitations

* Full log replay on new node → slow recovery

### V2 improvements

* Periodic **snapshot segments** (`offset → position` mapping)
* Device bookmark snapshot
* Restore using snapshot + tail replay

📌 *Outcome:* Cassandra-style bootstrap speed, Kafka-style correctness.

---

## **5. Consumer Groups & Fan-out Semantics**

### Limitations

* Device-level offsets only
* No group coordination

### V2 improvements

* Consumer groups with leader election and partition assignment
* Rebalance protocol for joining/leaving nodes
* Commit offsets per group
* At-least-once vs exactly-once delivery modes

📌 *Outcome:* Enterprise-grade consumption semantics.

---

## **6. Stronger Consistency Options**

### Limitations

* Best-effort consistency
* No fencing tokens

### V2 improvements

* Fencing tokens per shard leader
* Epoch numbers in manifest
* Reject writes from stale leaders
* Idempotent producers (producer_id + sequence)

📌 *Outcome:* Prevents split-brain and duplicates.

---

## **7. Observability & Tooling**

### Limitations

* Internal ETS metrics only
* No external visibility

### V2 improvements

* Metrics export: write latency, flush latency, compaction time, scan depth, backpressure events
* Prometheus endpoint
* Structured logs
* Admin CLI for:

  * Inspecting shards
  * Forcing compaction
  * Dumping offsets

📌 *Outcome:* Production operability and monitoring.

---

## **8. Backpressure & Flow Control**

### Limitations

* Backpressure only on buffer size

### V2 improvements

* Dynamic quotas per user/device
* Token-bucket rate limiting
* Per-shard write credits
* Client feedback (`retry-after`)

📌 *Outcome:* Predictable latency under load.

---

## **9. Storage Engine Enhancements**

### Limitations

* Single log per shard
* Manual index rebuild

### V2 improvements

* Multiple active segments per shard
* Segment size classes: hot / warm / cold
* Bloom filters for sparse index misses
* Background index rebuild workers
* Read cache with eviction policy

📌 *Outcome:* Better tail latency under heavy load.

---

## **10. Compaction Strategy Improvements**

### Limitations

* Fixed merge threshold
* Time-based TTL only

### V2 improvements

* Size-based compaction
* Load-aware compaction
* Priority queues for segments
* Compaction throttling
* Per-partition retention policies

📌 *Outcome:* Predictable disk usage.

---

## **11. Security & Multi-Tenancy**

### Limitations

* No isolation guarantees

### V2 improvements

* Per-tenant quotas
* Auth tokens on read/write
* Encryption-at-rest (segment-level)
* Audit log stream

📌 *Outcome:* Monetization-ready system.

---

## **12. Testing & Validation**

### Limitations

* No formal failure testing

### V2 improvements

* Chaos tests (kill shard leader, corrupt segment, partial write)
* Property-based tests
* Load replay tests
* Long-running soak tests

📌 *Outcome:* Confidence at scale.

---

## **13. API & Protocol Stability**

### Limitations

* Internal APIs only

### V2 improvements

* Stable wire protocol
* Versioned message format
* Compatibility guarantees
* Client SDKs (Elixir, JS, Java)

📌 *Outcome:* Ecosystem growth.

---

## **14. Documentation**

For V2, explicitly document:

* Architecture diagrams
* Write path
* Read path
* Failure modes
* Recovery flow
* Replication flow
* Compaction lifecycle
* Offset semantics
* Memory & disk bounds
* WAL & crash recovery behavior

📌 *This is what makes it “real” engineering.*

---

## **Final Reality Check**

* V1 is **RAM-first, ultra-low latency**, production-ready for signaling/fan-out workloads.
* V2 is **distributed, durable, replicated, and horizontally scalable**.
* You are **not fixing mistakes** in V2 — you are **adding features to move toward Kafka-class durability and observability**.

---

✅ This doc is **ready to share**, version-controlled, and gives engineers/scientists a clear picture of V2 priorities.

---

If you want, I can **also make a one-page diagram version** showing:

* **Write path:** Client → WAL → ETS → Segment
* **Read path:** ETS → Sparse Index → Disk
* **Crash recovery flow**

…which makes it immediately digestible for non-Elixir engineers.

Do you want me to do that next?
