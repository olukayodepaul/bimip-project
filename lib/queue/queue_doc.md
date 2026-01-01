### 1. `Queue.QueueLogImpl` (The Core Sharded Engine)

This is the "Brain" and "Hands" of the system. It manages the physical storage and retrieval of data.

* **Partitioning/Sharding:** It splits the data into **64 independent shards**. When a message arrives, it uses a hash of the `user_id` to decide which shard (GenServer) handles the request. This prevents a "hot user" from slowing down the entire system.
* **Two-Stage Writing:** To maximize throughput, it doesn't write to disk immediately. It first stores messages in a **Memory Buffer (ETS)**. Every 100ms (or when the buffer is full), it "flushes" those messages to the disk in a single batch.
* **The Reader Pool:** It maintains a pool of file descriptors for reading. Instead of opening and closing files for every fetch request (which is very slow), it keeps them open in an **LRU (Least Recently Used) cache**.
* **Indexing:** For every message written to a `.log` file, it writes a tiny entry into a `.idx` (index) file. This allows the system to find any message by its "Offset" instantly without scanning the whole file.

---

### 2. `Queue.BimipCompactor` (The Lifecycle Manager)

Since the queue is "Append-Only," files would grow forever if left alone. This module manages the disk space.

* **Historical Analysis:** It looks for "Segments" (files) that are no longer the active writing target.
* **TTL Enforcement:** It iterates through the index of old files. If a message is older than your `@retention_days` (7 days), it marks it for deletion.
* **Merging & Swapping:** It takes the surviving messages from multiple old files and "compacts" them into one new, clean file.
* **The Swap Call:** Once a new compacted file is ready, it sends a `:compact_swap` command to the `QueueLogImpl` to update the memory pointers to the new file and delete the old, bloated ones.

---

### 3. `Queue.MessageTracker` & `Sweeper` (The Deduplication Guard)

This module ensures that the same message isn't processed twice, which is a common problem in distributed systems when network retries occur.

* **Generational Storage:** It uses two "generations" of memory. Instead of one giant table that is hard to clean, it fills up "Generation A," then moves to "Generation B."
* **Persistent Term:** It uses `:persistent_term` to store which generation is currently active. This allows the system to check for duplicates with near-zero CPU overhead.
* **The Sweeper:** This is a background process that periodically "rotates" the generations. It wipes the oldest generation to clear out memory for new message IDs, ensuring the RAM usage stays flat.

---

### 4. `Queue.DeviceBookmark` (The State Tracker)

This module remembers the progress of every single device connected to the system.

* **Cursor Management:** It stores a "Bookmark" (an integer offset) for every `{device, user, partition}` triplet.
* **Hybrid Storage:** It uses **ETS** for ultra-fast lookups (so the device can ask "where am I?" constantly) and **Mnesia** to ensure that if the server reboots, the bookmark is not lost.
* **The "Advance" Logic:** It includes logic to ensure bookmarks only move forward. It prevents a device from accidentally overwriting a new progress marker with an older one.

---

### 5. `Queue.Persist` (The Data Architect)

This is a functional utility module that defines the "Contract" of what a message looks like.

* **Struct Construction:** It transforms raw input data into a strictly defined `%Bimip.Message{}` struct.
* **Metadata Tagging:** It injects system-level metadata into the message, such as the `writer_device`, `encryption_type`, and `transmission_mode`.
* **Layering:** It ensures that the storage engine (`QueueLogImpl`) doesn't need to know the details of the message content; it just sees a standardized package.

---

### 6. `Queue.Application` & `Supervisor` (The Safety Net)

* **Startup Orchestration:** These modules ensure the system starts in the correct order (e.g., creating the ETS tables before starting the Shards that need them).
* **Fault Tolerance:** If one shard crashes due to a corrupt file, the Supervisor restarts only that shard, leaving the other 63 shards running perfectly.

---

### Summary of Interaction

When a message is sent:

1. **Tracker** checks if we've seen it.
2. **Persist** builds the struct.
3. **QueueLogImpl** buffers it in memory and eventually flushes it to disk.
4. **Bookmark** tracks the reader's progress.
5. **Compactor** eventually deletes it when it gets too old.

**Now that you have a detailed view of the modules, would you like me to create a "Management API" module? This would allow you to see stats like "Total Messages Stored" or "Active Compaction Status" across all shards.**