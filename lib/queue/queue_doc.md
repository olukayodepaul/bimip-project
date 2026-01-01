### 1. `Queue.QueueLogImpl` (The Core Sharded Engine)

This module acts as the primary storage controller. It manages the **Active Segment** (the file currently receiving data) and handles all I/O operations.

* **Partitioning/Sharding:** Uses `:erlang.phash2(user, 64)` to distribute traffic across 64 individual GenServer workers. This ensures that a surge in one user's activity does not block others.
* **Two-Stage Writing (Buffered I/O):**
* **Stage 1:** In the `write/7` function, data is inserted into an ETS buffer (`log_buffer/1`).
* **Stage 2:** The `perform_flush/1` function runs every 100ms, batch-writing everything from the ETS buffer to disk in a single sequential burst.


* **Segment Rotation:** In `rotate_segment/1`, the engine monitors file sizes. Once a log exceeds `@max_segment_size` (100MB), it closes the files and creates a new "Segment" with a unique base ID.
* **The Reader Pool:** The `reader_fd/2` function manages a pool of open file descriptors in a cache (`:bimip_log_reader_pool`). This uses an **LRU (Least Recently Used)** eviction strategy via `evict_lru/1` to stay within the OS file limit.
* **Binary Alignment:** The `read_from_disk/3` function implements a precise binary pattern match to extract the payload using the header size (19 bytes) plus the variable username and metadata offsets.

---

### 2. `Queue.BimipCompactor` (The Lifecycle Manager)

This is a background maintenance worker that manages **Historical Segments** to ensure disk space is recycled and data integrity is maintained.

* **Historical Analysis:** The `find_historical_segments/1` function scans the disk for `.idx` files that are not currently locked by a shard's manifest.
* **Tail-Recursive Compaction:** The `process_idx_entries/7` function iterates through historical segments. It uses a **TTL (Time-To-Live)** check: `if ts > cutoff`. Records that pass are kept; those that fail (older than 7 days) are dropped.
* **Atomic Swapping:** After creating a new, smaller segment, it calls `GenServer.call(worker, {:compact_swap, ...})`. This triggers the `handle_call` in `QueueLogImpl` to atomically update the index cache and delete old files.
* **File Handle Safety:** It uses `copy_segment_with_retention/6` to open the source file once and stream data, preventing the "too many open files" error.

---

### 3. `Queue.MessageTracker` & `Sweeper` (The Deduplication Guard)

This module provides "Exactly-Once" delivery semantics by preventing duplicate messages from entering the system.

* **Two-Generation ETS:** `init/0` creates two sets of tables (Gen 0 and Gen 1). This allows for "Zero-Downtime" clearing of old data.
* **High-Speed Check:** `check_and_insert/4` uses a hash of the message key to find one of **256 partitions**. It checks the old generation first, then the current one, using `:ets.insert_new/2` for lock-free performance.
* **Persistent Term Optimization:** It stores the active generation index in `:persistent_term`. This allows every shard to know which table to write to without hitting a bottlenecked central GenServer.
* **The Sweeper:** `Queue.MessageTracker.Sweeper` manages the clock. It triggers `rotate/0` every 12 hours, which flips the active generation and clears the old one in a throttled background task to prevent CPU spikes.

---

### 4. `Queue.DeviceBookmark` (The State Tracker)

This module acts as the "Cursor" for every connected client, tracking exactly what they have read.

* **Startup Recovery:** The `startup/0` function initializes **Mnesia** for disk-based persistence and then calls `load_cache_from_mnesia/2` to warm up ETS caches for instant lookup speed.
* **Sharded Tracking:** Like the Log Engine, it shards bookmarks across 64 ETS tables to prevent lock contention when thousands of devices acknowledge messages simultaneously.
* **Monotonic Advancement:** The `advance/4` function ensures the consumer's position never moves backward, protecting against race conditions where an older acknowledgement might arrive after a newer one.

---

### 5. `Queue.Persist` (The Data Architect)

This is a pure functional module that ensures every message saved to disk follows a strict schema.

* **Struct Construction:** The `build/6` function takes the raw payload and wraps it in a `%Bimip.Message{}` struct.
* **Writer Attribution:** It explicitly assigns the `writer_device` to the struct. This is the crucial data point used by `fetch_for_device/4` in the Log Engine to filter out a device's own messages during a fetch.
* **Uniformity:** It ensures that whether a message is a "Chat," "System," or "Command" type, it is serialized into the same binary format for the storage engine.

---

### 6. `Queue.Application` & `Supervisor` (The Safety Net)

This module manages the system's "Tree of Life."

* **Boot Sequencing:** It calls `QueueLogImpl.__startup__` and `Queue.DeviceBookmark.startup` before starting any workers. This ensures all ETS tables exist before the Shards try to use them.
* **Granular Supervision:** Each of the 64 shards is supervised individually. If Shard 12 crashes due to a hardware I/O error, Shards 0–11 and 13–63 remain online and operational.

---

### Summary of Interaction

1. **Ingress:** A message arrives. `MessageTracker` ensures it’s not a duplicate.
2. **Structuring:** `Persist` creates the standardized `%Bimip.Message{}`.
3. **Storage:** `QueueLogImpl` saves it to an **Active Segment** on disk and updates the `.idx` file.
4. **Consumption:** A device asks for data. `DeviceBookmark` tells the system where to start reading. `QueueLogImpl` reads the segment, filtering out the message if the `writer_device` matches the caller.
5. **Maintenance:** `BimipCompactor` merges full segments and removes expired data to keep the system lean.
