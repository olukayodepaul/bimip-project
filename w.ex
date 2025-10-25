defmodule BimipQueue do
  @moduledoc """
  Kafka-style file-backed queue system using Mnesia for offsets.
  """

  @base_dir "data/bimip"
  @index_granularity 1000

  # ----------------------
  # Public API
  # ----------------------
  def write(user, partition_id, from, to, payload) do
    ensure_files_exist!(user, partition_id)
    queue_file = queue_file(user, partition_id)
    {:ok, fd} = File.open(queue_file, [:append, :binary])
    {:ok, pos} = :file.position(fd, :eof)

    next_offset = get_next_offset(user, partition_id)
    timestamp = DateTime.utc_now() |> DateTime.to_unix(:millisecond)

    record = %{
      offset: next_offset,
      partition_id: partition_id,
      from: from,
      to: to,
      payload: payload,
      ack: false,
      timestamp: timestamp
    }

    write_log_entry(fd, record)
    File.close(fd)

    # write index for every message (instead of only every 1000)
    append_index_file(user, partition_id, next_offset, pos)

    update_next_offset(user, partition_id, next_offset + 1)
    {:ok, next_offset}
  end


  def fetch(user, device_id, partition_id, limit \\ 10) do
    limit = if is_integer(limit), do: limit, else: String.to_integer(limit)
    last_offset = get_device_offset(user, device_id, partition_id)
    index_tree = recover_index(user, partition_id)

    sparse_lookup_offset = last_offset + 1
    iterator = :gb_trees.iterator_from(sparse_lookup_offset, index_tree)

    start_pos =
      case :gb_trees.next(iterator) do
        {:"$end_of_table", _} ->
          case :gb_trees.last(index_tree) do
            :"$end_of_table" -> 0
            {_offset, pos} -> pos
          end
        {{_offset, pos}, _} -> pos
      end

    queue_file = queue_file(user, partition_id)
    {:ok, fd} = File.open(queue_file, [:read, :binary])
    :file.position(fd, start_pos)

    messages =
      Stream.unfold(fd, fn fd_state ->
        case read_log_entry(fd_state) do
          :eof -> nil
          msg -> {msg, fd_state}
        end
      end)
      |> Enum.filter(fn msg -> msg.offset > last_offset end)
      |> Enum.take(limit)

    File.close(fd)

    new_last_offset =
      case List.last(messages) do
        nil -> last_offset
        last -> last.offset
      end

    set_device_offset(user, device_id, partition_id, new_last_offset)
    {:ok, messages, new_last_offset}
  end

  # ----------------------
  # Index Recovery
  # ----------------------
defp recover_index(user, partition_id) do
  idx_file = index_file(user, partition_id)

  cond do
    not File.exists?(idx_file) ->
      :gb_trees.empty()

    true ->
      case File.read(idx_file) do
        {:ok, ""} -> 
          :gb_trees.empty()
        {:ok, data} ->
          data
          |> Stream.chunk_every(16, 16, :discard)
          |> Enum.reduce(:gb_trees.empty(), fn <<offset::64, pos::64>>, tree ->
            :gb_trees.enter(offset, pos, tree)
          end)
        {:error, _} -> :gb_trees.empty()
      end
  end
end


  defp append_index_file(user, partition_id, offset, pos) do
    idx_file = index_file(user, partition_id)
    {:ok, fd} = File.open(idx_file, [:append, :binary])
    IO.binwrite(fd, <<offset::64, pos::64>>)
    File.close(fd)
  end

  # ----------------------
  # Log helpers
  # ----------------------
  defp write_log_entry(fd, record) do
    encoded = :erlang.term_to_binary(record)
    IO.binwrite(fd, <<byte_size(encoded)::32>> <> encoded)
  end

  defp read_log_entry(fd) do
    case :file.read(fd, 4) do
      {:ok, <<len::32>>} ->
        case :file.read(fd, len) do
          {:ok, bin} -> :erlang.binary_to_term(bin)
          _ -> :error
        end
      _ -> :eof
    end
  end

  # ----------------------
  # File helpers
  # ----------------------
  defp user_dir(user), do: Path.join(@base_dir, user)
  defp queue_file(user, partition_id), do: Path.join(user_dir(user), "queue_#{partition_id}.log")
  defp index_file(user, partition_id), do: Path.join(user_dir(user), "index_#{partition_id}.idx")

  defp ensure_files_exist!(user, partition_id) do
    File.mkdir_p!(user_dir(user))
    unless File.exists?(queue_file(user, partition_id)), do: File.write!(queue_file(user, partition_id), "")
    unless File.exists?(index_file(user, partition_id)), do: File.write!(index_file(user, partition_id), "")
  end

  # ----------------------
  # Mnesia-backed offsets
  # ----------------------
  defp get_next_offset(user, partition_id) do
    {:atomic, offset} =
      :mnesia.transaction(fn ->
        case :mnesia.match_object({:next_offsets, user, partition_id, :_}) do
          [{:next_offsets, _u, _p, offset}] -> offset
          [] ->
            :mnesia.write({:next_offsets, user, partition_id, 1})
            1
        end
      end)

    offset
  end

  defp update_next_offset(user, partition_id, offset) do
    :mnesia.transaction(fn ->
      :mnesia.write({:next_offsets, user, partition_id, offset})
    end)
  end

  defp get_device_offset(user, device_id, partition_id) do
    case :mnesia.transaction(fn ->
          case :mnesia.read({:device_offsets, user, device_id, partition_id}) do
            [{:device_offsets, _u, _d, _p, offset}] -> offset
            [] ->
              :mnesia.write({:device_offsets, user, device_id, partition_id, 0})
              0
          end
        end) do
      {:atomic, offset} -> offset
      {:aborted, _} -> 0
    end
  end

  defp set_device_offset(user, device_id, partition_id, offset) do
    :mnesia.transaction(fn ->
      :mnesia.write({:device_offsets, user, device_id, partition_id, offset})
    end)
  end
end










defmodule BimipQueueSparse do
  @moduledoc """
  Kafka-style queue system with sparse indexing for fast seek.
  """

  @base_dir "data/bimip"
  @index_granularity 1000

  # ----------------------
  # File helpers
  # ----------------------
  defp user_dir(user), do: Path.join(@base_dir, user)
  defp queue_file(user), do: Path.join(user_dir(user), "bimip_queue_#{user}.log")
  defp sparse_index_file(user), do: Path.join(user_dir(user), "bimip_sparse_index_#{user}.log")
  defp device_offset_file(user), do: Path.join(user_dir(user), "bimip_device_offset_#{user}.log")

  defp encode_term(term), do: :erlang.term_to_binary(term)
  defp decode_term(binary), do: :erlang.binary_to_term(binary)

  defp ensure_files_exist!(user) do
    File.mkdir_p!(user_dir(user))
    unless File.exists?(queue_file(user)), do: File.write!(queue_file(user), "")
    unless File.exists?(sparse_index_file(user)), do: File.write!(sparse_index_file(user), encode_term(%{}))
    unless File.exists?(device_offset_file(user)), do: File.write!(device_offset_file(user), encode_term(%{}))
  end

  # ----------------------
  # Sparse index helpers
  # ----------------------
  defp read_sparse_index(user) do
    ensure_files_exist!(user)
    File.read!(sparse_index_file(user)) |> decode_term()
  end

  defp write_sparse_index(user, index_map) do
    File.write!(sparse_index_file(user), encode_term(index_map))
  end

  # ----------------------
  # Device offsets
  # ----------------------
  defp read_device_offsets(user), do: decode_term(File.read!(device_offset_file(user)))
  defp write_device_offsets(user, offsets), do: File.write!(device_offset_file(user), encode_term(offsets))

  defp get_device_offset(user, device_id, partition), do: Map.get(read_device_offsets(user), {device_id, partition}, 0)
  defp update_device_offset(user, device_id, partition, offset) do
    offsets = read_device_offsets(user)
    write_device_offsets(user, Map.put(offsets, {device_id, partition}, offset))
  end

  # ----------------------
  # Log helpers
  # ----------------------
  defp write_log_entry(fd, record) do
    encoded = encode_term(record)
    IO.binwrite(fd, <<byte_size(encoded)::32>> <> encoded)
  end

  defp read_log_entry(fd) do
    case :file.read(fd, 4) do
      {:ok, <<len::32>>} ->
        case :file.read(fd, len) do
          {:ok, bin} -> decode_term(bin)
          _ -> :error
        end
      _ -> :eof
    end
  end

  # ----------------------
  # Write message
  # ----------------------
  def write(user, partition_id, from, to, payload) do
    ensure_files_exist!(user)

    {:ok, fd} = File.open(queue_file(user), [:append, :binary])
    {:ok, pos} = :file.position(fd, :eof)

    # Load sparse index
    index_map = read_sparse_index(user)
    partition_index = Map.get(index_map, partition_id, %{})

    # Determine next offset
    next_offset =
      if map_size(partition_index) == 0 do
        1
      else
        partition_index |> Map.keys() |> Enum.max() |> Kernel.+(1)
      end

    timestamp = DateTime.utc_now() |> DateTime.to_unix(:millisecond)

    record = %{
      offset: next_offset,
      partition_id: partition_id,
      from: from,
      to: to,
      payload: payload,
      ack: false,
      timestamp: timestamp
    }

    # Write message to log
    write_log_entry(fd, record)
    File.close(fd)

    # Update sparse index only every Nth message
    partition_index =
      if rem(next_offset, @index_granularity) == 0 do
        Map.put(partition_index, next_offset, pos)
      else
        partition_index
      end

    index_map = Map.put(index_map, partition_id, partition_index)
    write_sparse_index(user, index_map)

    {:ok, next_offset}
  end

  # ----------------------
  # Fetch messages
  # ----------------------
  def fetch(user, device_id, partition_id, limit \\ 10) do
    ensure_files_exist!(user)

    last_offset = get_device_offset(user, device_id, partition_id)
    index_map = read_sparse_index(user)
    partition_index = Map.get(index_map, partition_id, %{})

    # Find the nearest offset <= last_offset from sparse index
    {start_offset, start_pos} =
      partition_index
      |> Enum.filter(fn {offset, _} -> offset <= last_offset end)
      |> Enum.max_by(fn {offset, _} -> offset end, fn -> {0, 0} end)

    {:ok, fd} = File.open(queue_file(user), [:read, :binary])
    :file.position(fd, start_pos)

    # Read sequentially until reaching limit messages > last_offset
    messages =
      Stream.unfold(fd, fn fd_state ->
        case read_log_entry(fd_state) do
          :eof -> File.close(fd_state); nil
          msg -> {msg, fd_state}
        end
      end)
      |> Enum.filter(fn msg -> msg.offset > last_offset end)
      |> Enum.take(limit)

    File.close(fd)

    new_last_offset =
      case List.last(messages) do
        nil -> last_offset
        last -> last.offset
      end

    update_device_offset(user, device_id, partition_id, new_last_offset)
    {:ok, messages, new_last_offset}
  end
end



# defmodule BimipQueue do
#   @moduledoc """
#   Kafka-style file-backed queue system using Mnesia for offsets.
#   """

#   @base_dir "data/bimip"
#   @index_granularity 1000

#   # ----------------------
#   # Public API
#   # ----------------------
#   def write(user, partition_id, from, to, payload) do
#     ensure_files_exist!(user, partition_id)
#     queue_file = queue_file(user, partition_id)
#     {:ok, fd} = File.open(queue_file, [:append, :binary])
#     {:ok, pos} = :file.position(fd, :eof)

#     next_offset = get_next_offset(user, partition_id)
#     timestamp = DateTime.utc_now() |> DateTime.to_unix(:millisecond)

#     record = %{
#       offset: next_offset,
#       partition_id: partition_id,
#       from: from,
#       to: to,
#       payload: payload,
#       ack: false,
#       timestamp: timestamp
#     }

#     write_log_entry(fd, record)
#     File.close(fd)

#     if rem(next_offset, @index_granularity) == 0 do
#       append_index_file(user, partition_id, next_offset, pos)
#     end

#     update_next_offset(user, partition_id, next_offset + 1)
#     {:ok, next_offset}
#   end

#   def fetch(user, device_id, partition_id, limit \\ 10) do
#     last_offset = get_device_offset(user, device_id, partition_id)
#     index_tree = recover_index(user, partition_id)

#     sparse_lookup_offset = last_offset + 1
#     iterator = :gb_trees.iterator_from(sparse_lookup_offset, index_tree)

#     start_pos =
#       case :gb_trees.next(iterator) do
#         {:"$end_of_table", _} ->
#           case :gb_trees.last(index_tree) do
#             :none -> 0
#             {_offset, pos} -> pos
#           end
#         {{_offset, pos}, _} -> pos
#       end

#     queue_file = queue_file(user, partition_id)
#     {:ok, fd} = File.open(queue_file, [:read, :binary])
#     :file.position(fd, start_pos)

#     messages =
#       Stream.unfold(fd, fn fd_state ->
#         case read_log_entry(fd_state) do
#           :eof -> nil
#           msg -> {msg, fd_state}
#         end
#       end)
#       |> Enum.filter(fn msg -> msg.offset > last_offset end)
#       |> Enum.take(limit)

#     File.close(fd)

#     new_last_offset =
#       case List.last(messages) do
#         nil -> last_offset
#         last -> last.offset
#       end

#     set_device_offset(user, device_id, partition_id, new_last_offset)
#     {:ok, messages, new_last_offset}
#   end

#   # ----------------------
#   # Index Recovery
#   # ----------------------
#   defp recover_index(user, partition_id) do
#     idx_file = index_file(user, partition_id)

#     if File.exists?(idx_file) do
#       case File.read(idx_file) do
#         {:ok, ""} -> 
#           :gb_trees.empty()   # empty index
#         {:ok, data} ->
#           data
#           |> Stream.chunk_every(16, 16, :discard)
#           |> Enum.reduce(:gb_trees.empty(), fn <<offset::64, pos::64>>, tree ->
#             :gb_trees.enter(offset, pos, tree)
#           end)
#         {:error, _} -> :gb_trees.empty()
#       end
#     else
#       :gb_trees.empty()
#     end
#   end

#   defp append_index_file(user, partition_id, offset, pos) do
#     idx_file = index_file(user, partition_id)
#     {:ok, fd} = File.open(idx_file, [:append, :binary])
#     IO.binwrite(fd, <<offset::64, pos::64>>)
#     File.close(fd)
#   end

#   # ----------------------
#   # Log helpers
#   # ----------------------
#   defp write_log_entry(fd, record) do
#     encoded = :erlang.term_to_binary(record)
#     IO.binwrite(fd, <<byte_size(encoded)::32>> <> encoded)
#   end

#   defp read_log_entry(fd) do
#     case :file.read(fd, 4) do
#       {:ok, <<len::32>>} ->
#         case :file.read(fd, len) do
#           {:ok, bin} -> :erlang.binary_to_term(bin)
#           _ -> :error
#         end
#       _ -> :eof
#     end
#   end

#   # ----------------------
#   # File helpers
#   # ----------------------
#   defp user_dir(user), do: Path.join(@base_dir, user)
#   defp queue_file(user, partition_id), do: Path.join(user_dir(user), "queue_#{partition_id}.log")
#   defp index_file(user, partition_id), do: Path.join(user_dir(user), "index_#{partition_id}.idx")

#   defp ensure_files_exist!(user, partition_id) do
#     File.mkdir_p!(user_dir(user))
#     unless File.exists?(queue_file(user, partition_id)), do: File.write!(queue_file(user, partition_id), "")
#     unless File.exists?(index_file(user, partition_id)), do: File.write!(index_file(user, partition_id), "")
#   end

#   # ----------------------
#   # Mnesia-backed offsets
#   # ----------------------
# defp get_next_offset(user, partition_id) do
#   {:atomic, offset} =
#     :mnesia.transaction(fn ->
#       case :mnesia.match_object({:next_offsets, user, partition_id, :_}) do
#         [{:next_offsets, _u, _p, offset}] -> offset
#         [] ->
#           :mnesia.write({:next_offsets, user, partition_id, 1})
#           1
#       end
#     end)

#   offset
# end

# defp update_next_offset(user, partition_id, offset) do
#   :mnesia.transaction(fn ->
#     :mnesia.write({:next_offsets, user, partition_id, offset})
#   end)
# end

#   defp get_device_offset(user, device_id, partition_id) do
#     case :mnesia.transaction(fn ->
#           case :mnesia.read({:device_offsets, user, device_id, partition_id}) do
#             [{:device_offsets, _u, _d, _p, offset}] -> offset
#             [] ->
#               :mnesia.write({:device_offsets, user, device_id, partition_id, 0})
#               0
#           end
#         end) do
#       {:atomic, offset} -> offset
#       {:aborted, _} -> 0
#     end
#   end

#   defp set_device_offset(user, device_id, partition_id, offset) do
#     :mnesia.transaction(fn ->
#       :mnesia.write({:device_offsets, user, device_id, partition_id, offset})
#     end)
#   end
# end



# BimipQueueOptimized.view_queue("user1")
# BimipQueueOptimized.view_device_offsets("user1")
# BimipQueueOptimized.view_index("user1")


# BimipQueue.write("user1",2,"alice", "bob", "Hello Bob!")
# BimipQueue.write("user1",1,"alice_2", "bob", "Hello Bob!")

# BimipQueue.write("alice", 1, "alice", "bob", "Hello Bob!")
# BimipQueue.write("alice", 1, "alice", "bob", "Hello Bob!")
# BimipQueue.write("alice", 1, "alice", "bob", "Hello Bob!")
# BimipQueue.write("alice", 1, "alice", "bob", "Hello Bob!")
# BimipQueue.fetch("alice", "alice", 1, "bob")

# def fetch(user, device_id, partition_id, limit \\ 10) do


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
