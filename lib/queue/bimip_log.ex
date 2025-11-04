defmodule BimipLog do
  @moduledoc """
  BimipLog — append-only per-user/device log with per-device pending ACKs.

  Features:
    - File-backed segments with sparse index (Now correctly implemented for fast seeks)
    - Per-device pending ACKs (MapSet) to avoid full log scans
    - Commit offsets advanced to the highest acknowledged offset (preserved original behavior)
    - Supports millions of users/devices efficiently

  Usage:
    - Call `BimipLog.ensure_mnesia_tables/0` at app start.
    - `write/5` appends messages.
    - `fetch/4` retrieves unacknowledged messages starting at commit_offset+1.
    - `ack_message/4` acknowledges a message.
  """

  require Logger

  @base_dir "data/bimip"
  @index_granularity 1
  @segment_size_limit 50 # demo size, increase in production

  # ----------------------
  # Public: Ensure tables (Cleaned up: removed unused :device_offsets table)
  # ----------------------
  def ensure_mnesia_tables do
    :mnesia.start()

    tables = [
      {:current_segment, [:key, :seg]},
      {:first_segment, [:key, :seg]},
      {:next_offsets, [:key, :offset]},
      {:segment_cache, [:key, :pos]},
      # Removed :device_offsets as it was unused.
      {:commit_offsets, [:key, :offset]},
      {:pending_acks, [:key, :set]}
    ]

    Enum.each(tables, fn {t, attrs} ->
      case :mnesia.create_table(t, attributes: attrs, disc_copies: [node()], type: :set) do
        {:atomic, :ok} -> Logger.debug("Table #{t} created")
        {:aborted, {:already_exists, ^t}} -> :ok
        other -> Logger.debug("mnesia create_table #{inspect(t)} -> #{inspect(other)}")
      end
    end)

    :ok
  end

  # ----------------------
  # Public API
  # ----------------------
  @doc "Append a message to a user's partition log"
  def write(user, partition_id, from, to, payload, user_offset \\ nil) do
    with :ok <- ensure_files_exist(user, partition_id),
        {:ok, %{seg: seg, next_offset: next_offset, do_rollover: do_rollover}} <- get_atomic_write_state(user, partition_id) do
        
      qfile = queue_file(user, partition_id, seg)

      case File.open(qfile, [:append, :binary]) do
        {:ok, fd} ->
          {:ok, pos_before} = :file.position(fd, :eof)

          timestamp = DateTime.utc_now() |> DateTime.to_unix(:millisecond)
    
          offset_payload = PersistMessage.build(%{from: from, to: to, payload: payload}, next_offset, user_offset)

          record = %{
            offset: next_offset,
            partition_id: partition_id,
            payload: offset_payload,
            timestamp: timestamp
          }

          result =
            case write_log_entry(fd, record) do
              :ok ->
                :ok = finalize_write_state(user, partition_id, seg, next_offset, pos_before, do_rollover)
                {:ok, next_offset}

              {:error, reason} ->
                Logger.error("Failed to write log entry: #{inspect(reason)}")
                {:error, reason}
            end

          File.close(fd)
          result

        {:error, reason} ->
          Logger.error("Failed to open segment file #{qfile}: #{inspect(reason)}")
          {:error, reason}
      end
    else
      {:error, reason} ->
        Logger.error("Failed to acquire atomic write state: #{inspect(reason)}")
        {:error, reason}
    end
  end

  @doc """
  Fetch up to `limit` messages for a device starting at its commit_offset + 1
  """
  # ----------------------
  # Fetch messages (FIXED: Uses lookup_sparse_index and accounts for segment cache)
  # ----------------------
  def fetch(user, device_id, partition_id, limit \\ 10) when limit > 0 do
    with :ok <- ensure_files_exist(user, partition_id),
         :ok <- ensure_device_files_exist(user, device_id, partition_id),
         {:ok, commit_offset} <- get_commit_offset(user, device_id, partition_id),
         {:ok, current_seg} <- get_current_segment(user, partition_id),
         {:ok, first_seg} <- get_first_segment(user, partition_id) do

      target_offset = commit_offset + 1
      # 1. Sparse Index Lookup (Now functional)
      {_indexed_offset, start_seg_from_idx, start_pos_from_idx} = lookup_sparse_index(user, partition_id, target_offset)

      # Ensure we don't start before the first existing segment
      start_seg = max(start_seg_from_idx, first_seg)

      {messages, last_offset_read} =
        Enum.reduce_while(start_seg..current_seg, {[], commit_offset}, fn seg, {acc, last} ->
          qfile = queue_file(user, partition_id, seg)

          if not File.exists?(qfile) do
            {:cont, {acc, last}}
          else
            case File.open(qfile, [:read, :binary]) do
              {:ok, fd} ->
                # Pass the index-derived start position for this segment
                index_start_pos_for_seg = if seg == start_seg, do: start_pos_from_idx, else: 0

                result =
                  read_segment_from_fd(
                    fd,
                    target_offset,
                    acc,
                    last,
                    limit,
                    user,
                    device_id,
                    partition_id,
                    seg,
                    index_start_pos_for_seg
                  )

                File.close(fd)
                result

              {:error, reason} ->
                Logger.error("Failed to open segment file #{qfile}: #{inspect(reason)}")
                {:cont, {acc, last}}
            end
          end
        end)

      {:ok,
        %{
          messages: messages,
          device_offset: commit_offset,
          target_offset: target_offset,
          current_segment: current_seg,
          first_segment: first_seg
        }}
    else
      {:error, reason} -> {:error, reason}
    end
  end

  # ----------------------
  # Atomic Write Helpers
  # ----------------------
  defp get_atomic_write_state(user, partition_id) do
    seg_key = {user, partition_id}
    offset_key = {user, partition_id}

    case :mnesia.transaction(fn ->
      current_seg = case :mnesia.read(:current_segment, seg_key) do
        [{:current_segment, ^seg_key, seg}] -> seg
        [] -> 1
      end

      next_offset = case :mnesia.read(:next_offsets, offset_key) do
        [{:next_offsets, ^offset_key, offset}] -> offset
        [] -> 1
      end

      qfile = queue_file(user, partition_id, current_seg)
      do_rollover = case File.stat(qfile) do
        {:ok, stat} when stat.size >= @segment_size_limit -> true
        _ -> false
      end

      :mnesia.write({:next_offsets, offset_key, next_offset + 1})
      new_seg = if do_rollover, do: current_seg + 1, else: current_seg

      {:ok, %{seg: new_seg, next_offset: next_offset, do_rollover: do_rollover}}
    end) do
      {:atomic, result} -> result
      {:aborted, reason} -> {:error, {:mnesia_aborted, reason}}
    end
  end

  defp finalize_write_state(user, partition_id, current_seg, offset, pos_before, do_rollover) do
    if do_rollover do
      new_seg = current_seg + 1
      set_current_segment(user, partition_id, new_seg)
      File.touch(queue_file(user, partition_id, new_seg))
      Logger.info("✅ Segment rolled over: #{current_seg} → #{new_seg}")
    end

    if rem(offset, @index_granularity) == 0 do
      append_index_file(user, partition_id, current_seg, offset, pos_before)
    end

    :ok
  end

  # ----------------------
  # Read segment helper (FIXED: Added segment cache logic for efficiency)
  # ----------------------
  defp read_segment_from_fd(fd, target_offset, acc, last, limit, user, device_id, partition_id, seg, index_start_pos) do
    # 2. Check segment cache for the last read position by this device
    {:ok, cache_pos} = get_segment_cache(user, device_id, partition_id, seg)
    # Start at the maximum of the sparse index position (if applicable) or the cached position
    start_pos = max(index_start_pos, cache_pos)
    :file.position(fd, start_pos)

    stream =
      Stream.unfold(fd, fn fd_state ->
        case read_log_entry(fd_state) do
          :eof -> nil
          {:corrupt, _} -> nil # Stop reading segment on corruption
          {:ok, msg} -> {msg, fd_state}
          _ -> nil
        end
      end)

    # Filter messages starting from the target_offset (commit_offset + 1)
    # and take only enough to fill the limit
    msgs =
      stream
      |> Stream.filter(fn m -> m.offset >= target_offset end)
      |> Enum.take(limit - length(acc))

    new_acc = acc ++ msgs

    new_last =
      case List.last(msgs) do
        nil -> last
        msg -> msg.offset
      end

    # 3. Update the segment cache with the current file position
    case :file.position(fd, :cur) do
      {:ok, cur_pos} -> set_segment_cache(user, device_id, partition_id, seg, cur_pos)
      _ -> :ok
    end

    # Halt or continue reducing the segments
    if length(new_acc) >= limit do
      {:halt, {new_acc, new_last}}
    else
      {:cont, {new_acc, new_last}}
    end
  end

  # ----------------------
  # Segment cache helpers
  # ----------------------
  defp get_segment_cache(user, device_id, partition_id, seg) do
    key = {user, device_id, partition_id, seg}
    case :mnesia.transaction(fn -> :mnesia.read(:segment_cache, key) end) do
      {:atomic, [{:segment_cache, ^key, pos}]} -> {:ok, pos}
      {:atomic, []} -> {:ok, 0}
      {:aborted, reason} -> {:error, {:mnesia_aborted, reason}}
    end
  end

  defp set_segment_cache(user, device_id, partition_id, seg, pos) do
    key = {user, device_id, partition_id, seg}
    :mnesia.transaction(fn -> :mnesia.write({:segment_cache, key, pos}) end)
  end

  # ----------------------
  # Segment helpers
  # ----------------------
  defp get_current_segment(user, partition_id) do
    key = {user, partition_id}
    case :mnesia.transaction(fn -> :mnesia.read(:current_segment, key) end) do
      {:atomic, [{:current_segment, ^key, seg}]} -> {:ok, seg}
      {:atomic, []} -> {:ok, 1}
      {:aborted, reason} -> {:error, {:mnesia_aborted, reason}}
    end
  end

  defp set_current_segment(user, partition_id, seg) do
    key = {user, partition_id}
    :mnesia.transaction(fn -> :mnesia.write({:current_segment, key, seg}) end)
  end

  defp get_first_segment(user, partition_id) do
    key = {user, partition_id}
    case :mnesia.transaction(fn -> :mnesia.read(:first_segment, key) end) do
      {:atomic, [{:first_segment, ^key, seg}]} -> {:ok, seg}
      {:atomic, []} -> {:ok, 1}
      {:aborted, reason} -> {:error, {:mnesia_aborted, reason}}
    end
  end

  defp set_first_segment(user, partition_id, seg) do
    key = {user, partition_id}
    :mnesia.transaction(fn -> :mnesia.write({:first_segment, key, seg}) end)
  end

  # ----------------------
  # Commit offsets
  # ----------------------
  defp get_commit_offset(user, device_id, partition_id) do
    key = {user, device_id, partition_id}
    case :mnesia.transaction(fn -> :mnesia.read(:commit_offsets, key) end) do
      {:atomic, [{:commit_offsets, ^key, offset}]} -> {:ok, offset}
      {:atomic, []} -> {:ok, 0}
      {:aborted, reason} -> {:error, {:mnesia_aborted, reason}}
    end
  end

  defp set_commit_offset(user, device_id, partition_id, offset) do
    key = {user, device_id, partition_id}
    :mnesia.transaction(fn -> :mnesia.write({:commit_offsets, key, offset}) end)
  end

  # ----------------------
  # ACK / Commit logic (Original non-contiguous logic preserved)
  # ----------------------
  @doc "Public ack API"
  def ack_message(user, device_id, partition_id, offset) do
    key = {user, device_id, partition_id}

    {:atomic, {:ok, new_commit}} =
      :mnesia.transaction(fn ->
        # Current commit offset
        commit =
          case :mnesia.read(:commit_offsets, key) do
            [{:commit_offsets, ^key, c}] -> c
            [] -> 0
          end

        # Current pending set
        pending =
          case :mnesia.read(:pending_acks, key) do
            [{:pending_acks, ^key, s}] -> s
            [] -> MapSet.new()
          end

        # Add new ack to pending if beyond commit
        pending = if offset > commit, do: MapSet.put(pending, offset), else: pending

        # Advance commit to the **highest acked offset** (even if out-of-order)
        new_commit = advance_commit_to_max(pending, commit)

        # Remove all offsets ≤ new_commit from pending
        new_pending = MapSet.filter(pending, fn x -> x > new_commit end)

        # Save updated commit & pending
        :mnesia.write({:commit_offsets, key, new_commit})
        :mnesia.write({:pending_acks, key, new_pending})

        {:ok, new_commit}
      end)

    {:ok, new_commit}
  end

  # Advance commit to highest acked offset (preserves non-contiguous behavior)
  defp advance_commit_to_max(pending, commit) do
    if MapSet.size(pending) == 0 do
      commit
    else
      max_offset = Enum.max(pending)
      max(max_offset, commit)
    end
  end

  def acked?(user, device_id, partition_id, offset) do
    key = {user, device_id, partition_id}

    case :mnesia.transaction(fn ->
           commit =
             case :mnesia.read(:commit_offsets, key) do
               [{:commit_offsets, ^key, c}] -> c
               [] -> 0
             end

           pending =
             case :mnesia.read(:pending_acks, key) do
               [{:pending_acks, ^key, s}] -> s
               [] -> MapSet.new()
             end

           {:ok, commit, pending}
         end) do
      {:atomic, {:ok, commit, _pending}} ->
        offset <= commit

      _ -> false
    end
  end

  # Returns {new_commit, remaining_pending_set} (Still present but unused, preserving original code)
  defp consume_contiguous(pending_set, commit) do
    next = commit + 1
    if MapSet.member?(pending_set, next) do
      consume_contiguous(MapSet.delete(pending_set, next), next)
    else
      {commit, pending_set}
    end
  end

  # ----------------------
  # File & sparse index helpers (FIXED: Sparse index now performs binary search)
  # ----------------------
  defp user_dir(user), do: Path.join(@base_dir, user)
  defp queue_file(user, partition_id, seg), do: Path.join(user_dir(user), "queue_#{partition_id}_#{seg}.log")
  defp index_file(user, partition_id), do: Path.join(user_dir(user), "index_#{partition_id}.idx")

  defp ensure_files_exist(user, _partition_id), do: File.mkdir_p(user_dir(user))

  defp ensure_device_files_exist(_user, _device_id, _partition_id), do: :ok

  defp append_index_file(user, partition_id, seg, offset, pos) do
    idx_file = index_file(user, partition_id)
    case File.open(idx_file, [:append, :binary]) do
      {:ok, fd} ->
        # Index record: <<offset::64, seg::32, pos::64>> (20 bytes)
        :ok = IO.binwrite(fd, <<offset::64, seg::32, pos::64>>)
        File.close(fd)
        :ok
      {:error, reason} -> {:error, reason}
    end
  end

  # Implements binary search over the sparse index file to find the nearest log position
  defp lookup_sparse_index(user, partition_id, target_offset) do
    idx = index_file(user, partition_id)
    case File.stat(idx) do
      {:ok, %{size: size}} when size >= 20 ->
        entries = div(size, 20)
        case File.open(idx, [:read, :binary]) do
          {:ok, fd} ->
            res = binary_search_index_fd(fd, target_offset, 0, entries - 1, {0, 1, 0})
            File.close(fd)
            res
          {:error, _} -> {0, 1, 0}
        end
      _ -> {0, 1, 0}
    end
  end

  defp binary_search_index_fd(_fd, _target, low, high, best) when low > high, do: best
  defp binary_search_index_fd(fd, target_offset, low, high, best) do
    mid = div(low + high, 2)
    pos = mid * 20
    case :file.position(fd, pos) do
      {:ok, _} ->
        # Read index record: <<offset::64, seg::32, pos::64>>
        case :file.read(fd, 20) do
          {:ok, <<offset::64, seg::32, pos64::64>>} ->
            cond do
              # Exact match
              offset == target_offset -> {offset, seg, pos64}
              # Offset is before the target, so this is the new best starting point
              offset < target_offset -> binary_search_index_fd(fd, target_offset, mid + 1, high, {offset, seg, pos64})
              # Offset is after the target, search lower half
              offset > target_offset -> binary_search_index_fd(fd, target_offset, low, mid - 1, best)
            end
          _ -> best
        end
      _ -> best
    end
  end

  # ----------------------
  # Log entry serialization with CRC32
  # ----------------------
  defp write_log_entry(fd, record) do
    try do
      data = :erlang.term_to_binary(record)
      crc = :erlang.crc32(data)
      IO.binwrite(fd, <<byte_size(data)::32, crc::32, data::binary>>)
      :ok
    rescue
      e -> {:error, e}
    end
  end

  defp read_log_entry(fd) do
    case :file.read(fd, 8) do
      {:ok, <<size::32, crc::32>>} ->
        case :file.read(fd, size) do
          {:ok, bin} ->
            if :erlang.crc32(bin) == crc do
              {:ok, :erlang.binary_to_term(bin)}
            else
              {:corrupt, :crc_mismatch}
            end
          :eof -> :eof
        end
      :eof -> :eof
      {:error, reason} -> {:corrupt, reason}
    end
  end
end

# {:ok, offset} = BimipLog.write("user1", 1, "alice", "bob", "Hello World")
# {:ok, result} = BimipLog.fetch("a@domain.com_b@domain.com", "aaaaa1", 1, 10)
# BimipLog.fetch("a@domain.com_b@domain.com", "aaaaa1", 1, 50)
# BimipLog.fetch("b@domain.com_a@domain.com", "aaaaa2", 1, 50)
# BimipLog.ack_message("a@domain.com_b@domain.com", "aaaaa1", 1, 7)

# BimipLog.fetch("b@domain.com_a@domain.com", "bbbbb2", 1, 50)
# BimipLog.ack_message("b@domain.com_a@domain.com", "bbbbb2", 1, 30)
# BimipLog.fetch("b@domain.com_a@domain.com", "bbbbb2", 1, 50)