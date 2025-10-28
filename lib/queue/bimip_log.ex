defmodule BimipLog do
  @moduledoc """
  Append-only log writer/reader with a sparse index for fast seeks.

  - Chat messages (the payload) are written to per-user, per-partition segment log files.
  - Small metadata (segment pointers, offsets, commit offsets, ack table) are stored in Mnesia.
  - Sparse index entries are binary tuples (20 bytes): offset::64, seg::32, pos::64
  """

  require Logger

  @base_dir "data/bimip"
  @index_granularity 1
  @segment_size_limit 50 # demo; increase in prod

  # ----------------------
  # Public API
  # ----------------------

  @doc """
  Append a message to the user's partition log.
  Returns {:ok, offset} or {:error, reason}.
  1
  """
  @spec write(String.t(), integer(), any(), any(), any()) :: {:ok, non_neg_integer()} | {:error, any()}
  def write(user, partition_id, from, to, payload) do
    with :ok <- ensure_files_exist(user, partition_id),
         seg <- get_current_segment(user, partition_id),
         qfile <- queue_file(user, partition_id, seg),
         {:ok, fd} <- File.open(qfile, [:append, :binary]),
         {:ok, pos_before} <- :file.position(fd, :eof),
         next_offset <- get_next_offset(user, partition_id),
         timestamp <- DateTime.utc_now() |> DateTime.to_unix(:millisecond),
         record = %{
           offset: next_offset,
           partition_id: partition_id,
           from: from,
           to: to,
           payload: payload,
           timestamp: timestamp
         },
         :ok <- write_log_entry(fd, record),
         :ok <- File.close(fd) do

      # rollover check
      case File.stat(qfile) do
        {:ok, stat} when stat.size >= @segment_size_limit ->
          new_seg = seg + 1
          set_current_segment(user, partition_id, new_seg)
          # create new file so next writer finds it
          File.touch(queue_file(user, partition_id, new_seg))
          Logger.info("✅ Segment rolled over: #{seg} → #{new_seg}")
        _ ->
          :ok
      end

      # index append
      if rem(next_offset, @index_granularity) == 0 do
        append_index_file(user, partition_id, seg, next_offset, pos_before)
      end

      update_next_offset(user, partition_id, next_offset + 1)
      {:ok, next_offset}
    else
      {:error, reason} ->
        Logger.error("Failed to write log entry: #{inspect(reason)}")
        {:error, reason}

      other ->
        Logger.error("Failed to write log entry: #{inspect(other)}")
        {:error, other}
    end
  end

  @doc """
  Fetch up to `limit` messages for `device_id` starting at its committed offset + 1.
  Returns {:ok, %{messages: [...], device_offset: n, ...}} or {:error, reason}
  1
  """
  @spec fetch(String.t(), String.t(), integer(), non_neg_integer()) ::
          {:ok, map()} | {:error, any()}
@doc """
Fetch up to `limit` messages for `device_id` starting at its committed offset + 1.
Returns {:ok, %{messages: [...], device_offset: n, ...}} or {:error, reason}
"""
@spec fetch(String.t(), String.t(), integer(), non_neg_integer()) ::
        {:ok, map()} | {:error, any()}
def fetch(user, device_id, partition_id, limit \\ 10) when limit > 0 do
  with :ok <- ensure_files_exist(user, partition_id),
       :ok <- ensure_device_files_exist(user, device_id, partition_id) do
    last_offset = get_commit_offset(user, device_id, partition_id)
    target_offset = last_offset + 1

    current_seg = get_current_segment(user, partition_id)
    first_seg = get_first_segment(user, partition_id)

    {_indexed_offset, start_seg, start_pos} = lookup_sparse_index(user, partition_id, target_offset)

    {messages, last_offset_read} =
      Enum.reduce_while(start_seg..current_seg, {[], last_offset}, fn seg, {acc, last} ->
        qfile = queue_file(user, partition_id, seg)

        if not File.exists?(qfile) do
          {:cont, {acc, last}}
        else
          # --- OPTIMIZATION START ---
          case File.open(qfile, [:read, :binary]) do
            {:ok, fd} ->
              # Calculate starting position: 0 for non-indexed segments, start_pos for the first indexed segment
              pos = if seg == start_seg, do: start_pos, else: 0

              result = read_segment_from_fd(fd, pos, target_offset, acc, last, limit)
              File.close(fd) # Close the file immediately after reading the segment
              result

            {:error, reason} ->
              Logger.error("Failed to open segment file #{qfile}: #{inspect(reason)}")
              {:cont, {acc, last}} # Skip this segment and continue
          end
          # --- OPTIMIZATION END ---
        end
      end)

    # persist device offset (last read)
    set_device_offset(user, device_id, partition_id, last_offset_read)

    {:ok,
     %{
       messages: messages,
       device_offset: last_offset_read,
       target_offset: target_offset,
       current_segment: current_seg,
       first_segment: first_seg
     }}
  else
    {:error, reason} ->
      {:error, reason}
  end
end


# read_segment_from_fd: reads from an open file descriptor, filters by offset, stops when limit reached
defp read_segment_from_fd(fd, start_pos, target_offset, acc, last, limit) do
  # Set the position based on the sparse index lookup
  :file.position(fd, start_pos)

  stream =
    Stream.unfold(fd, fn fd_state ->
      case read_log_entry(fd_state) do
        :eof ->
          nil
        {:corrupt, reason} ->
          Logger.warn("Skipping corrupt entry in segment: #{inspect(reason)}")
          nil # Stop on corruption to avoid skipping messages that appear after it
        {:ok, msg} ->
          {msg, fd_state}
        _other_error -> # Catch any other error/return value from read_log_entry/1
          Logger.error("Unexpected error reading log entry: #{inspect(_other_error)}")
          nil
      end
    end)

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

  if length(new_acc) >= limit do
    {:halt, {new_acc, new_last}} # Signal Enum.reduce_while to stop processing segments
  else
    {:cont, {new_acc, new_last}} # Continue to the next segment
  end
end

  # ----------------------
  # Segment helpers (Mnesia-backed)
  # ----------------------
  defp get_current_segment(user, partition_id) do
    key = {user, partition_id}

    case :mnesia.transaction(fn -> :mnesia.read(:current_segment, key) end) do
      {:atomic, [{:current_segment, ^key, seg}]} -> seg
      {:atomic, []} ->
        :mnesia.transaction(fn -> :mnesia.write({:current_segment, key, 1}) end)
        1
      {:aborted, _} ->
        1
    end
  end

  defp set_current_segment(user, partition_id, seg) do
    key = {user, partition_id}
    :mnesia.transaction(fn -> :mnesia.write({:current_segment, key, seg}) end)
  end

  defp queue_file(user, partition_id, seg) do
    Path.join(user_dir(user), "queue_#{partition_id}_#{seg}.log")
  end

  # ----------------------
  # Device offsets (Mnesia)
  # ----------------------
  defp get_device_offset(user, device_id, partition_id) do
    key = {user, device_id, partition_id}

    case :mnesia.transaction(fn -> :mnesia.read(:device_offsets, key) end) do
      {:atomic, [{:device_offsets, ^key, offset}]} -> offset
      {:atomic, []} ->
        :mnesia.transaction(fn -> :mnesia.write({:device_offsets, key, 0}) end)
        0
      {:aborted, _} ->
        0
    end
  end

  defp set_device_offset(user, device_id, partition_id, offset) do
    key = {user, device_id, partition_id}
    :mnesia.transaction(fn -> :mnesia.write({:device_offsets, key, offset}) end)
  end

  # ----------------------
  # First segment (Mnesia)
  # ----------------------
  def set_first_segment(user, partition_id, seg) do
    key = {user, partition_id}
    :mnesia.transaction(fn -> :mnesia.write({:first_segment, key, seg}) end)
  end

  def get_first_segment(user, partition_id) do
    key = {user, partition_id}

    case :mnesia.transaction(fn -> :mnesia.read(:first_segment, key) end) do
      {:atomic, [{:first_segment, ^key, seg}]} -> seg
      {:atomic, []} -> 1
      {:aborted, _} -> 1
    end
  end

  # ----------------------
  # File helpers
  # ----------------------
  defp user_dir(user), do: Path.join(@base_dir, user)
  defp index_file(user, partition_id), do: Path.join(user_dir(user), "index_#{partition_id}.idx")

  defp ensure_files_exist(user, _partition_id) do
    case File.mkdir_p(user_dir(user)) do
      :ok -> :ok
      {:error, reason} ->
        Logger.error("Failed to ensure user dir exists: #{inspect(reason)}")
        {:error, reason}
    end
  end

  defp ensure_device_files_exist(user, device_id, partition_id) do
    offset_file = device_offset_file(user, device_id, partition_id)
    idx_file = device_index_file(user, device_id, partition_id)

    try do
      unless File.exists?(offset_file) do
        File.write!(offset_file, :erlang.term_to_binary(%{offset: 0}))
      end

      unless File.exists?(idx_file) do
        File.write!(idx_file, "")
      end

      :ok
    rescue
      err ->
        Logger.error("Failed to ensure device files exist: #{inspect(err)}")
        {:error, err}
    end
  end

  defp device_index_file(user, device_id, partition_id),
    do: Path.join(user_dir(user), "index_#{device_id}_#{partition_id}.idx")

  defp device_offset_file(user, device_id, partition_id),
    do: Path.join(user_dir(user), "offset_#{device_id}_#{partition_id}.dat")

  # ----------------------
  # Sparse index append (simple append)
  # ----------------------
  defp append_index_file(user, partition_id, seg, offset, pos) do
    idx_file = index_file(user, partition_id)

    case File.open(idx_file, [:append, :binary]) do
      {:ok, fd} ->
        :ok = IO.binwrite(fd, <<offset::64, seg::32, pos::64>>)
        File.close(fd)
        :ok

      {:error, reason} ->
        Logger.error("Failed to append index: #{inspect(reason)}")
        {:error, reason}
    end
  end

  # ----------------------
  # Sparse index lookup (streaming binary search)
  # ----------------------
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

          {:error, _} ->
            {0, 1, 0}
        end

      _ ->
        {0, 1, 0}
    end
  end

  # Use file descriptor reads to avoid reading whole index into memory
  defp binary_search_index_fd(_fd, _target, low, high, best) when low > high, do: best

  defp binary_search_index_fd(fd, target_offset, low, high, best) do
    mid = div(low + high, 2)
    pos = mid * 20

    case :file.position(fd, pos) do
      {:ok, _} ->
        case :file.read(fd, 20) do
          {:ok, <<offset::64, seg::32, pos64::64>>} ->
            cond do
              offset == target_offset -> {offset, seg, pos64}
              offset < target_offset -> binary_search_index_fd(fd, target_offset, mid + 1, high, {offset, seg, pos64})
              offset > target_offset -> binary_search_index_fd(fd, target_offset, low, mid - 1, best)
            end

          _read_err ->
            best
        end

      _ ->
        best
    end
  end

  # ----------------------
  # Log helpers
  # ----------------------
  defp write_log_entry(fd, record) do
    encoded = :erlang.term_to_binary(record)
    crc = :erlang.crc32(encoded)
    case IO.binwrite(fd, <<byte_size(encoded)::32, crc::32>> <> encoded) do
      :ok -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp read_log_entry(fd) do
    case :file.read(fd, 8) do
      :eof ->
        :eof

      {:ok, <<len::32, crc::32>>} ->
        case :file.read(fd, len) do
          :eof ->
            :eof

          {:ok, bin} ->
            if :erlang.crc32(bin) == crc do
              {:ok, :erlang.binary_to_term(bin)}
            else
              {:corrupt, :crc_mismatch}
            end

          {:error, reason} ->
            {:error, reason}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end


  # read_segment: read sequentially, filter by offset >= target_offset, stop when limit reached
  defp read_segment(qfile, target_offset, acc, last, limit) do
    case File.open(qfile, [:read, :binary]) do
      {:ok, fd} ->
        try do
          :file.position(fd, 0)
          stream =
            Stream.unfold(fd, fn fd_state ->
              case read_log_entry(fd_state) do
                :eof -> nil
                {:corrupt, _} ->
                  # skip corrupt entries but stop at corruption to avoid skew
                  nil
                {:ok, msg} ->
                  {msg, fd_state}
                _ -> nil
              end
            end)

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

          if length(new_acc) >= limit do
            {:halt, {new_acc, new_last}}
          else
            {:cont, {new_acc, new_last}}
          end
        after
          File.close(fd)
        end

      {:error, _} ->
        {:cont, {acc, last}}
    end
  end

  # ----------------------
  # Next offsets per {user, partition_id} (Mnesia)
  # ----------------------
  defp get_next_offset(user, partition_id) do
    key = {user, partition_id}

    case :mnesia.transaction(fn -> :mnesia.read(:next_offsets, key) end) do
      {:atomic, [{:next_offsets, ^key, offset}]} -> offset
      {:atomic, []} ->
        :mnesia.transaction(fn -> :mnesia.write({:next_offsets, key, 1}) end)
        1
      {:aborted, _} -> 1
    end
  end

  defp update_next_offset(user, partition_id, offset) do
    key = {user, partition_id}
    :mnesia.transaction(fn -> :mnesia.write({:next_offsets, key, offset}) end)
  end

  # ----------------------
  # ACK table (gap-tolerant)
  # ----------------------
  def ack_message(user, device_id, partition_id, offset) do
    commit_ack(user, device_id, partition_id, offset)
  end

  def acked?(user, device_id, partition_id, offset) do
    key = {user, device_id, partition_id, offset}

    case :mnesia.transaction(fn -> :mnesia.read(:ack_table, key) end) do
      {:atomic, [{:ack_table, ^key, true}]} -> true
      _ -> false
    end
  end

  # ----------------------
  # Commit offsets (gap-tolerant)
  # ----------------------
  defp commit_ack(user, device_id, partition_id, offset) do
    key = {user, device_id, partition_id, offset}

    :mnesia.transaction(fn ->
      :mnesia.write({:ack_table, key, true})
    end)

    update_commit_offset(user, device_id, partition_id)
  end

  defp update_commit_offset(user, device_id, partition_id) do
    last_commit = get_commit_offset(user, device_id, partition_id)

    {:atomic, acked_keys} =
      :mnesia.transaction(fn ->
        :mnesia.match_object({:ack_table, {user, device_id, partition_id, :_}, true})
      end)

    acked_offsets =
      acked_keys
      |> Enum.map(fn {:ack_table, {^user, ^device_id, ^partition_id, off}, true} -> off end)
      |> Enum.filter(&(&1 > last_commit))

    if acked_offsets == [] do
      last_commit
    else
      new_commit = Enum.max(acked_offsets)
      set_commit_offset(user, device_id, partition_id, new_commit)
      new_commit
    end
  end

  # ----------------------
  # Commit offsets storage
  # ----------------------
  def get_commit_offset(user, device_id, partition_id) do
    key = {user, device_id, partition_id}

    case :mnesia.transaction(fn -> :mnesia.read(:commit_offsets, key) end) do
      {:atomic, [{:commit_offsets, ^key, offset}]} -> offset
      {:atomic, []} ->
        :mnesia.transaction(fn -> :mnesia.write({:commit_offsets, key, 0}) end)
        0
      {:aborted, _} -> 0
    end
  end

  defp set_commit_offset(user, device_id, partition_id, offset) do
    key = {user, device_id, partition_id}
    :mnesia.transaction(fn -> :mnesia.write({:commit_offsets, key, offset}) end)
  end
end


# {:ok, offset} = BimipLog.write("user1", 1, "alice", "bob", "Hello World")
# {:ok, result} = BimipLog.fetch("user1", "device1", 1, 10)
# BimipLog.ack_message("user1", "device1", 1, 12)