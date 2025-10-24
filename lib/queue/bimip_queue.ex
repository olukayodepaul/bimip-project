# Perfect, Paul 👌 — you’re now entering *system evolution thinking*,
# which is what turns a working Elixir file-queue into a **distributed message broker**.

# Let’s outline a **clear version roadmap** so you know what to scale next.
# We’ll go from **local & simple (v1)** to **replicated & distributed (v3)** — all while keeping your core `bimip_queue` concept intact.

# ---

# ## 🚀 **Version 1 (Current) — Local Persistent Queue**

# ✅ **Already implemented**

# ### Core Features

# * Simple **file-based queue** using `bimip_queue.dat`
# * **Binary serialization** via `:erlang.term_to_binary`
# * **Index tracking** via `bimip_queue_index.dat`
# * **Monotonic offsets** (safe to store in GenServer)
# * **Append-only writes** (no offset shifts)
# * **Acknowledgement support**
# * **Per-user partitioning** (`from`, `to`, `partition_id`)

# ### Limitations

# * Single-node only
# * No replication or sharding
# * File can grow indefinitely
# * Fetch performance drops if file gets very large
# * No automatic recovery if file corrupts mid-write

# ---

# ## ⚙️ **Version 2 — Scalable & Durable Architecture**

# The goal of version 2 is **horizontal scaling and durability**, while keeping the same file core.

# ### 🔧 Key Additions

# #### 1. **Sharding (Partition Scaling)**

# * Split queue files per partition (e.g., `bimip_queue_1.dat`, `bimip_queue_2.dat`)
# * Use a hash on `(partition_id, from, to)` to decide shard
# * Each shard runs in its **own GenServer**, possibly supervised dynamically
# * Enables concurrency and better CPU/disk utilization

# #### 2. **Leader/Follower Replication**

# * Each shard has a **leader process** (primary writer)
# * One or more **followers** replicate the log via message streaming or file copy
# * Can use `Node.connect/1` and `:rpc.call/4` for simple BEAM replication
# * Leader handles writes; followers apply in order (exactly-once)

# #### 3. **Compaction Process**

# * Background process (`BimipQueue.Compactor`) scans acknowledged messages
# * Writes a new compacted file and swaps atomically
# * Updates offsets safely
# * Prevents unbounded file growth

# #### 4. **Recovery Mechanism**

# * On startup, validate the queue file

#   * Rebuild index if missing or corrupted
#   * Ignore partial writes (by checking valid binary endings)

# #### 5. **Metrics and Monitoring**

# * Track `message_count`, `ack_count`, `file_size`, and `throughput`
# * Optional telemetry integration (`:telemetry` or `prom_ex`)

# ---

# ## 🌐 **Version 3 — Distributed Message Broker (Kafka-style)**

# The goal here is full **distributed fault-tolerant messaging**.

# ### 🧱 Key Additions

# #### 1. **Cluster Replication**

# * Multi-node deployment using Erlang distribution (`Node.connect`)
# * Raft-like consensus to elect shard leaders
#   (use `:ra` library or `:gen_statem`-based custom consensus)
# * Data replicated across nodes → fault tolerance

# #### 2. **Producer / Consumer API**

# * Add `produce/3` and `consume/3` interfaces

#   * `produce/3` → appends messages with at-least-once guarantee
#   * `consume/3` → reads sequentially from offset, commits ack
# * Consumer offset stored per client (like Kafka consumer groups)

# #### 3. **Retention Policy**

# * Auto-delete or archive old messages (e.g., after 7 days)
# * Configurable per partition or queue

# #### 4. **Network Protocol / API**

# * Introduce lightweight gRPC or WebSocket API for external clients

#   * So other microservices or mobile clients can connect
#   * You could use your existing `grpcbox` and `cowboy` knowledge

# #### 5. **Fault-Tolerant Storage**

# * Replace file with Mnesia, ETS-backed segments, or RocksDB (via NIF)
# * Optionally enable write-ahead log (WAL) to prevent loss

# #### 6. **Security Layer**

# * Add authentication (JWT integration)
# * Encrypted file writes or TLS on network layer

# #### 7. **Observability & Admin Tools**

# * CLI or dashboard to inspect offsets, partitions, and queue health
# * Command-line tools:

#   * `bimip_queue list`
#   * `bimip_queue compact`
#   * `bimip_queue stats`

# ---

# ## 📊 Summary Table

# | Version | Focus               | Storage        | Scale                    | Fault Tolerance    | Replication       | Network Access   |
# | ------- | ------------------- | -------------- | ------------------------ | ------------------ | ----------------- | ---------------- |
# | **v1**  | Core persistence    | Single file    | Single-node              | None               | ❌                 | Local only       |
# | **v2**  | Shards + compaction | Multiple files | Multi-core / Single-node | Partial            | Leader → follower | Optional         |
# | **v3**  | Distributed broker  | Sharded logs   | Multi-node               | Strong (consensus) | ✅                 | gRPC / WebSocket |

# ---

# ## 🧩 Suggested Next Steps

# * ✅ Finalize and benchmark v1 (current) for throughput and correctness
# * 🔜 Begin v2 by introducing `partition_shard` supervisor
# * 🔜 Design replication model (leader-follower async write)
# * 🧪 Add background compaction and recovery

# ---

# Would you like me to draft a **version 2 project layout** (with file paths and module structure) to help you start refactoring toward sharding and compaction next?



# Perfect ✅ — here’s a **high-level roadmap for v2 and v3** of your `BimipQueue`, focusing on **distribution and replication**.

# ---

# ## **Version 2: Distributed Queue (Multiple Nodes)**

# **Goal:** Scale beyond a single server while keeping your existing per-user queue logic.

# ### 1️⃣ Node Partitioning

# * Partition users across nodes based on **prefix or hash**.
# * Each node owns a set of prefixes (e.g., 256 prefixes, 5 nodes → ~50 prefixes per node).

# Example:

# ```
# Node 1: prefixes 00–33
# Node 2: prefixes 34–66
# Node 3: prefixes 67–99
# Node 4: prefixes 9a–cc
# Node 5: prefixes cd–ff
# ```

# ### 2️⃣ Routing Requests

# * When writing or fetching, determine **which node owns the user** by prefix.
# * Route the request to that node (via HTTP/gRPC or direct BEAM node calls).

# ### 3️⃣ Advantages

# * Reduces load per node.
# * No change in per-user queue logic.
# * Easy to scale by adding nodes and rebalancing prefixes.

# ---

# ## **Version 3: Replication & Fault Tolerance**

# **Goal:** Ensure durability and high availability like Kafka.

# ### 1️⃣ Replication

# * Each prefix/user is **replicated to multiple nodes** (e.g., 3 replicas).
# * Writes go to **leader node**; followers replicate messages asynchronously.
# * Followers can serve reads if configured.

# ### 2️⃣ Leader-Follower Mechanism

# * Each prefix (or user) has **one leader** node.
# * Followers replicate the append-only file and acknowledge replication.
# * Leader failure → one follower becomes new leader.

# ### 3️⃣ Offset Tracking

# * Keep **offsets per replica**.
# * Commit acknowledged offsets once replication is confirmed.

# ### 4️⃣ Benefits

# * Survives node failures.
# * Provides high availability and durability.
# * Allows scaling read-heavy workloads across replicas.

# ---

# ## **Single Node → Distributed Migration**

# 1. Start with single-node implementation (current code, prefix sharding).
# 2. Introduce **node discovery and routing layer**.
# 3. Add **replication and leader election** per prefix.

# ---

# If you want, I can **draw a simple diagram showing v1, v2, and v3 flow**, so you can visually see how users, prefixes, nodes, and replicas relate.

# Do you want me to do that?


defmodule BimipQueue do
  @moduledoc """
  Per-user file-based message queue with numeric monotonic offsets shared across devices.

  Folder structure (with prefix sharding):
    data/bimip/<prefix>/<user>/
      - bimip_queue_<user>.dat
      - bimip_queue_index_<user>.dat

  The prefix is derived from a hash of the username (00–ff), 
  distributing users evenly across 256 folders.

  All devices of the same sender share the same offset sequence per partition.
  """

  @base_dir "data/bimip"

  # ==============================
  # Prefix-based sharding helpers
  # ==============================

  defp user_prefix(user) do
    user
    |> :erlang.phash2(256)
    |> Integer.to_string(16)
    |> String.pad_leading(2, "0")
  end

  defp user_dir(user) do
    prefix = user_prefix(user)
    Path.join([@base_dir, prefix, user])
  end

  defp queue_file(user), do: Path.join(user_dir(user), "bimip_queue_#{user}.dat")
  defp index_file(user), do: Path.join(user_dir(user), "bimip_queue_index_#{user}.dat")

  # ==============================
  # File helpers
  # ==============================

  defp ensure_files_exist!(user) do
    dir = user_dir(user)
    File.mkdir_p!(dir)

    qf = queue_file(user)
    ix = index_file(user)

    unless File.exists?(qf), do: File.write!(qf, "")
    unless File.exists?(ix), do: File.write!(ix, encode_term([]))
  end

  defp encode_term(term), do: term |> :erlang.term_to_binary() |> Base.encode64()
  defp decode_term(str), do: str |> Base.decode64!() |> :erlang.binary_to_term()

  # ==============================
  # Index helpers
  # ==============================

  defp read_index(user) do
    ensure_files_exist!(user)

    case File.read(index_file(user)) do
      {:ok, ""} -> []
      {:ok, content} -> decode_term(content)
      _ -> []
    end
  end

  defp write_index(user, indexes),
    do: File.write!(index_file(user), encode_term(indexes))

  # Only partition_id and from matter for offset
  defp next_offset_for(user, partition_id, from) do
    indexes = read_index(user)

    case Enum.find(indexes, fn i ->
           i.partition_id == partition_id and i.from == from
         end) do
      nil -> 0
      %{next_offset: n} -> n
    end
  end

  defp update_index(user, partition_id, from, next_offset) do
    indexes = read_index(user)

    new_indexes =
      case Enum.find_index(indexes, fn i ->
            i.partition_id == partition_id and i.from == from
          end) do
        nil ->
          [%{partition_id: partition_id, from: from, next_offset: next_offset} | indexes]

        idx ->
          List.update_at(indexes, idx, fn i -> %{i | next_offset: next_offset} end)
      end

    write_index(user, new_indexes)
  end

  # ==============================
  # Public API
  # ==============================

  @doc """
  Writes a new message to the queue.
  All devices for the same sender share the same offset per partition.
  Returns {:ok, offset}.
  """
  def write(user, partition_id, from, to, payload) do
    ensure_files_exist!(user)

    offset = next_offset_for(user, partition_id, from)
    timestamp = DateTime.utc_now() |> DateTime.to_unix(:millisecond)

    record = %{
      offset: offset,
      partition_id: partition_id,
      from: from,
      to: to,
      payload: payload,
      timestamp: timestamp,
      acknowledged: false
    }

    File.write!(queue_file(user), encode_term(record) <> "\n", [:append])
    update_index(user, partition_id, from, offset + 1)

    {:ok, offset}
  end

  # ==============================
  # Fetch helpers
  # ==============================

  @doc """
  Fetch all messages (backward-compatible)
  """
  def fetch(user, partition_id, from, to, limit \\ 10, offset \\ 0) do
    fetch_by_ack_status(user, partition_id, from, to, limit, offset, :all)
  end

  @doc """
  Fetch only unacknowledged messages.
  """
  def fetch_unack(user, partition_id, from, to, limit \\ 10, offset \\ 0) do
    fetch_by_ack_status(user, partition_id, from, to, limit, offset, false)
  end

  @doc """
  Fetch only acknowledged messages.
  """
  def fetch_ack(user, partition_id, from, to, limit \\ 10, offset \\ 0) do
    fetch_by_ack_status(user, partition_id, from, to, limit, offset, true)
  end

  defp fetch_by_ack_status(user, partition_id, from, to, limit, offset, ack_status) do
    ensure_files_exist!(user)
    {:ok, content} = File.read(queue_file(user))

    messages =
      content
      |> String.split("\n", trim: true)
      |> Enum.map(&decode_term/1)
      |> Enum.filter(fn rec ->
        rec.partition_id == partition_id and rec.from == from and rec.to == to and
          rec.offset >= offset and
          (ack_status == :all or rec.acknowledged == ack_status)
      end)
      |> Enum.sort_by(& &1.offset)
      |> Enum.take(limit)

    next_offset =
      case List.last(messages) do
        nil -> offset
        last -> last.offset + 1
      end

    {:ok, messages, next_offset}
  end

  # ==============================
  # Ack
  # ==============================

  @doc """
  Marks all messages up to a given offset as acknowledged.
  """
  def ack(user, partition_id, from, to, last_offset) do
    ensure_files_exist!(user)
    {:ok, content} = File.read(queue_file(user))

    updated =
      content
      |> String.split("\n", trim: true)
      |> Enum.map(fn line ->
        rec = decode_term(line)

        if rec.partition_id == partition_id and rec.from == from and rec.to == to and
            rec.offset <= last_offset do
          %{rec | acknowledged: true}
        else
          rec
        end
      end)
      |> Enum.map(&encode_term/1)
      |> Enum.join("\n")

    File.write!(queue_file(user), updated <> "\n")
    :ok
  end


  @doc """
  Update the last offset for a user and partition.

  All devices for the same sender share the same offset per partition.
  """
  def update_last_offset(user, partition_id, from, next_offset) do
    ensure_files_exist!(user)

    indexes = read_index(user)

    new_indexes =
      case Enum.find_index(indexes, fn i ->
            i.partition_id == partition_id and i.from == from
          end) do
        nil ->
          [%{partition_id: partition_id, from: from, next_offset: next_offset} | indexes]

        idx ->
          List.update_at(indexes, idx, fn i -> %{i | next_offset: next_offset} end)
      end

    write_index(user, new_indexes)
    :ok
  end


  @doc """
  Returns all index entries for debugging.
  """
  def list_indexes(user), do: read_index(user)
end



# # iex -S mix

# BimipQueue.write("user_1", "partition_a", "user_1", "user_2", %{msg: "Hello world"})
# BimipQueue.fetch("user_1", "partition_a", "user_1", "user_2", 10, 0)
# BimipQueue.write("user_1", "partition_a", "user_1", "user_2", %{msg: "Hello world"})

# # Only unacknowledged messages
# BimipQueue.fetch_unack("user_1", "partition_a", "user_1", "user_2", 10, 0)

# # Only acknowledged messages
# BimipQueue.fetch_ack("user_1", "partition_a", "user_1", "user_2", 10, 0)

# # All messages
# BimipQueue.fetch("user_1", "partition_a", "user_1", "user_2", 10, 1)

# BimipQueue.ack("user_1", "partition_a", "user_1", "user_2", 0)




# Assume BimipQueue module is compiled and loaded

# user = "paul@id"
# partition = "chat_a"
# from = "paul@id"

# # ---------------------------
# # Write messages for device_1
# # ---------------------------
# {:ok, offset1} = BimipQueue.write(user, partition, from, "device_1", %{msg: "Hello from device_1 - 1"})
# {:ok, offset2} = BimipQueue.write(user, partition, from, "device_1", %{msg: "Hello from device_1 - 2"})

# # ---------------------------
# # Write messages for device_2
# # ---------------------------
# {:ok, offset3} = BimipQueue.write(user, partition, from, "device_2", %{msg: "Hello from device_2 - 1"})

# # ---------------------------
# # Write messages for device_3
# # ---------------------------
# {:ok, offset4} = BimipQueue.write(user, partition, from, "device_3", %{msg: "Hello from device_3 - 1"})

# # ---------------------------
# # Fetch unacknowledged messages for device_1
# # ---------------------------
# {:ok, messages_d1, next_offset_d1} = BimipQueue.fetch_unack(user, partition, from, "device_1", 10, 0)
# IO.inspect(messages_d1, label: "Device 1 - Unacknowledged messages")
# IO.puts("Next offset: #{next_offset_d1}")

# # ---------------------------
# # Acknowledge the first message for device_1
# # ---------------------------
# BimipQueue.ack(user, partition, from, "device_1", offset1)
# {:ok, messages_d1_post_ack, _} = BimipQueue.fetch_unack(user, partition, from, "device_1", 10, 0)
# IO.inspect(messages_d1_post_ack, label: "Device 1 - After ack offset1")

# # ---------------------------
# # Fetch acknowledged messages for device_1
# # ---------------------------
# {:ok, acked_d1, _} = BimipQueue.fetch_ack(user, partition, from, "device_1", 10, 0)
# IO.inspect(acked_d1, label: "Device 1 - Acknowledged messages")

# # ---------------------------
# # Fetch all messages for device_2
# # ---------------------------
# {:ok, all_d2, _} = BimipQueue.fetch(user, partition, from, "device_2", 10, 0)
# IO.inspect(all_d2, label: "Device 2 - All messages")



# BimipQueue.ack(user, partition, from, "device_3", 2) 
# BimipQueue.fetch_by_ack_status(user, partition, from, "device_3", 10, 2, true)
