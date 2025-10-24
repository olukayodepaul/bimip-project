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



defmodule BimipQueueOptimized do
  @moduledoc """
  Optimized queue system using :array for partition indexes.
  """

  @base_dir "data/bimip"

  # ----------------------
  # File helpers
  # ----------------------
  defp user_dir(user), do: Path.join([@base_dir, user])
  defp queue_file(user), do: Path.join(user_dir(user), "bimip_queue_#{user}.dat")
  defp index_file(user), do: Path.join(user_dir(user), "bimip_index_#{user}.dat")
  defp device_offset_file(user), do: Path.join(user_dir(user), "bimip_device_offset_#{user}.dat")

  defp encode_term(term), do: term |> :erlang.term_to_binary() |> Base.encode64()
  defp decode_term(str), do: str |> Base.decode64!() |> :erlang.binary_to_term()

  defp ensure_files_exist!(user) do
    File.mkdir_p!(user_dir(user))
    unless File.exists?(queue_file(user)), do: File.write!(queue_file(user), "")
    unless File.exists?(index_file(user)), do: File.write!(index_file(user), encode_term(%{}))
    unless File.exists?(device_offset_file(user)), do: File.write!(device_offset_file(user), encode_term(%{}))
  end

  # ----------------------
  # Index helpers
  # ----------------------
  defp read_index(user) do
    ensure_files_exist!(user)
    File.read!(index_file(user)) |> decode_term()
  end

  defp write_index(user, index), do: File.write!(index_file(user), encode_term(index))

  # ----------------------
  # Device offset helpers
  # ----------------------
  defp read_device_offsets(user) do
    ensure_files_exist!(user)
    File.read!(device_offset_file(user)) |> decode_term()
  end

  defp write_device_offsets(user, offsets), do: File.write!(device_offset_file(user), encode_term(offsets))

  defp get_device_offset(user, device_id, partition) do
    read_device_offsets(user) |> Map.get({device_id, partition}, 0)
  end

  defp update_device_offset(user, device_id, partition, offset) do
    offsets = read_device_offsets(user)
    new_offsets = Map.put(offsets, {device_id, partition}, offset)
    write_device_offsets(user, new_offsets)
  end

  # ----------------------
  # Write message
  # ----------------------
  def write(user, partition_id, from, to, payload) do
    ensure_files_exist!(user)

    {:ok, queue_fd} = File.open(queue_file(user), [:append, :binary])
    {:ok, pos} = :file.position(queue_fd, :eof)

    index = read_index(user)

    # Get or initialize partition array
    partition_index = Map.get(index, partition_id, :array.new())

    # Compute next offset
    offset =
      case :array.size(partition_index) do
        0 -> 1
        size ->
          {last_off, _} = :array.get(size - 1, partition_index)
          last_off + 1
      end

    timestamp = DateTime.utc_now() |> DateTime.to_unix(:millisecond)
    record = %{offset: offset, partition_id: partition_id, from: from, to: to, payload: payload, ack: false, timestamp: timestamp}

    IO.binwrite(queue_fd, encode_term(record) <> "\n")
    File.close(queue_fd)

    # Insert into array
    new_partition_index = :array.set(:array.size(partition_index), {offset, pos}, partition_index)
    new_index = Map.put(index, partition_id, new_partition_index)
    write_index(user, new_index)

    {:ok, offset}
  end

  # ----------------------
  # Fetch messages
  # ----------------------
def fetch(user, device_id, partition_id, _to, limit \\ 10) do
  ensure_files_exist!(user)

  last_offset = get_device_offset(user, device_id, partition_id)
  partition_index = Map.get(read_index(user), partition_id, :array.new())
  total = :array.size(partition_index)

  # Binary search for first offset > last_offset
  start_idx = binary_search(partition_index, last_offset, 0, total - 1)

  # Nothing to fetch
  if start_idx >= total do
    {:ok, [], last_offset}
  else
    end_idx = min(start_idx + limit - 1, total - 1)
    {:ok, queue_fd} = File.open(queue_file(user), [:read, :binary])

    messages =
      for i <- start_idx..end_idx do
        case :array.get(i, partition_index) do
          :undefined -> nil
          {off, pos} ->
            :file.position(queue_fd, pos)
            line = IO.read(queue_fd, :line)
            decode_term(String.trim(line))
        end
      end
      |> Enum.reject(&is_nil/1)

    File.close(queue_fd)

    # Update device offset
    new_last_offset =
      case List.last(messages) do
        nil -> last_offset
        last -> last.offset
      end

    update_device_offset(user, device_id, partition_id, new_last_offset)
    {:ok, messages, new_last_offset}
  end
end


  # ----------------------
  # Binary search helper
  # ----------------------
  defp binary_search(arr, last_offset, low, high) when low > high, do: low

  defp binary_search(arr, last_offset, low, high) do
    mid = div(low + high, 2)
    {off, _pos} = :array.get(mid, arr)

    cond do
      off <= last_offset -> binary_search(arr, last_offset, mid + 1, high)
      off > last_offset -> binary_search(arr, last_offset, low, mid - 1)
    end
  end

  # ----------------------
  # Debug helpers
  # ----------------------
  def view_queue(user) do
    ensure_files_exist!(user)
    File.read!(queue_file(user))
    |> String.split("\n", trim: true)
    |> Enum.map(&decode_term/1)
  end

  def view_index(user) do
    read_index(user)
    |> Enum.map(fn {k, arr} -> {k, :array.to_list(arr)} end)
    |> Enum.into(%{})
  end

  def view_device_offsets(user), do: read_device_offsets(user)
end


# BimipQueueOptimized.view_queue("user1")
# BimipQueueOptimized.view_device_offsets("user1")
# BimipQueueOptimized.view_index("user1")

# BimipQueueOptimized.write("user1",1,"alice", "bob", "Hello Bob!")
# BimipQueueOptimized.write("user1",1,"alice", "bob", "Hello Bob!")
# BimipQueueOptimized.write("user1",1,"alice_2", "bob", "Hello Bob!")
# BimipQueueOptimized.write("user1",1,"alice_2", "bob", "Hello Bob!")
# BimipQueueOptimized.write("user1",2,"alice", "bob", "Hello Bob!")
# BimipQueueOptimized.write("user1",2,"alice", "bob", "Hello Bob!")
# BimipQueueOptimized.fetch("user1", "alice", 2, "bob")