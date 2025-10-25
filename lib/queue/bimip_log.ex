defmodule BimipLog do
  @moduledoc """
  File-backed queue with:
    - binary length-prefixed log entries (safe random access),
    - CRC checksum per entry for corruption detection,
    - shared sparse index per partition (offset -> file position),
    - per-device offsets stored in Mnesia,
    - per-device index checkpoint files for faster recovery (optional),
    - support for first_segment tracking,
    - automatic segmented logs with size limit.
  """

  require Logger

  @base_dir "data/bimip"
  @index_granularity 1
  @segment_size_limit 500

  # ----------------------
  # Public API
  # ----------------------
def write(user, partition_id, from, to, payload) do
    ensure_files_exist!(user, partition_id)

    # Get current segment
    seg = get_current_segment(user, partition_id)
    qfile = queue_file(user, partition_id, seg)

    # Open file in append mode
    {:ok, fd} = File.open(qfile, [:append, :binary])
    {:ok, pos_before} = :file.position(fd, :eof)

    # Compute next offset
    next_offset = get_next_offset(user, partition_id)
    timestamp = DateTime.utc_now() |> DateTime.to_unix(:millisecond)

    # Build record
    record = %{
      offset: next_offset,
      partition_id: partition_id,
      from: from,
      to: to,
      payload: payload,
      timestamp: timestamp
    }

    # Write record
    write_log_entry(fd, record)
    File.close(fd)

    # Debug: file size
    {:ok, stat} = File.stat(qfile)
    IO.puts("File: #{qfile}, size after write: #{stat.size}")

    # Roll over segment if file exceeds threshold
    if stat.size >= @segment_size_limit do
      new_seg = seg + 1
      set_current_segment(user, partition_id, new_seg)

      # Create the new log file
      new_qfile = queue_file(user, partition_id, new_seg)
      File.touch(new_qfile)
      IO.puts("✅ Segment rolled over: #{seg} → #{new_seg}")
    end

    # Update index every N messages
    if rem(next_offset, @index_granularity) == 0 do
      append_index_file(user, partition_id, next_offset, pos_before)
    end

    # Update next offset
    update_next_offset(user, partition_id, next_offset + 1)

    {:ok, next_offset}
  end

  def fetch(user, device_id, partition_id, limit \\ 10) do
    ensure_files_exist!(user, partition_id)
    ensure_device_files_exist!(user, device_id, partition_id)

    last_offset = get_device_offset(user, device_id, partition_id)
    first_seg = get_first_segment(user, partition_id)
    current_seg = get_current_segment(user, partition_id)

    {messages, next_offset} =
      Enum.reduce_while(first_seg..current_seg, {[], last_offset}, fn seg, {acc, last} ->
        qfile = queue_file(user, partition_id, seg)

        if not File.exists?(qfile) do
          {:cont, {acc, last}}
        else
          {:ok, fd} = File.open(qfile, [:read, :binary])

          {:ok, seg_messages} =
            try do
              Stream.unfold(fd, fn fd_state ->
                case read_log_entry(fd_state) do
                  :eof -> nil
                  {:corrupt, reason} ->
                    Logger.error("⚠️ Corrupt entry detected: #{inspect(reason)}")
                    nil
                  msg -> {msg, fd_state}
                end
              end)
              |> Stream.filter(fn msg -> is_map(msg) and msg.offset > last end)
              |> Enum.take(limit - length(acc))
              |> then(&{:ok, &1})
            after
              File.close(fd)
            end

          new_acc = acc ++ seg_messages
          new_last =
            case List.last(seg_messages) do
              nil -> last
              last_msg -> last_msg.offset
            end

          if length(new_acc) >= limit, do: {:halt, {new_acc, new_last}}, else: {:cont, {new_acc, new_last}}
        end
      end)

    # Update device offset and device index file
    set_device_offset(user, device_id, partition_id, next_offset)

    if messages != [] do
      last_seg = get_current_segment(user, partition_id)
      qfile = queue_file(user, partition_id, last_seg)
      {:ok, pos} = File.stat(qfile)
      append_device_index_file(user, device_id, partition_id, next_offset, pos.size)
    end

    {:ok, messages, next_offset}
  end

  # ----------------------
  # Segment helpers
  # ----------------------
  defp get_current_segment(user, partition_id) do
    {:atomic, result} =
      :mnesia.transaction(fn ->
        :mnesia.match_object({:current_segment, user, partition_id, :_})
      end)

    case result do
      [{:current_segment, ^user, ^partition_id, seg}] -> seg
      [] ->
        :mnesia.transaction(fn ->
          :mnesia.write({:current_segment, user, partition_id, 1})
        end)
        1
    end
  end

  defp set_current_segment(user, partition_id, seg) do
    :mnesia.transaction(fn ->
      :mnesia.write({:current_segment, user, partition_id, seg})
    end)
  end

  def queue_file(user, partition_id, seg),
    do: Path.join(user_dir(user), "queue_#{partition_id}_#{seg}.log")

  # ----------------------
  # Device index helper
  # ----------------------
  defp append_device_index_file(user, device_id, partition_id, offset, pos) do
    idx_file = device_index_file(user, device_id, partition_id)
    {:ok, fd} = File.open(idx_file, [:append, :binary])
    IO.binwrite(fd, <<offset::64, pos::64>>)
    File.close(fd)
  end

  # ----------------------
  # First Segment Support
  # ----------------------
  def set_first_segment(user, partition_id, seg) do
    key = "__partition__#{partition_id}"
    :mnesia.transaction(fn ->
      :mnesia.write({:first_segment, key, user, partition_id, seg})
    end)
  end

  def get_first_segment(_user, partition_id) do
    key = "__partition__#{partition_id}"

    case :mnesia.transaction(fn -> :mnesia.read(:first_segment, key) end) do
      {:atomic, [{:first_segment, _key, _user, _partition_id, seg}]} -> seg
      _ -> 1
    end
  end

  # ----------------------
  # File Helpers
  # ----------------------
  defp user_dir(user), do: Path.join(@base_dir, user)
  defp index_file(user, partition_id), do: Path.join(user_dir(user), "index_#{partition_id}.idx")
  defp device_index_file(user, device_id, partition_id),
    do: Path.join(user_dir(user), "index_#{device_id}_#{partition_id}.idx")

  defp device_offset_file(user, device_id, partition_id),
    do: Path.join(user_dir(user), "offset_#{device_id}_#{partition_id}.dat")

  defp ensure_files_exist!(user, _partition_id) do
    File.mkdir_p!(user_dir(user))
  end

  defp ensure_device_files_exist!(user, device_id, partition_id) do
    offset_file = device_offset_file(user, device_id, partition_id)
    index_file = device_index_file(user, device_id, partition_id)
    unless File.exists?(offset_file), do: File.write!(offset_file, :erlang.term_to_binary(%{offset: 0}))
    unless File.exists?(index_file), do: File.write!(index_file, "")
  end

  # ----------------------
  # Sparse Index
  # ----------------------
  defp append_index_file(user, partition_id, offset, pos) do
    idx_file = index_file(user, partition_id)
    {:ok, fd} = File.open(idx_file, [:append, :binary])
    IO.binwrite(fd, <<offset::64, pos::64>>)
    File.close(fd)
  end

  # ----------------------
  # Log Helpers
  # ----------------------
  defp write_log_entry(fd, record) do
    encoded = :erlang.term_to_binary(record)
    crc = :erlang.crc32(encoded)
    IO.binwrite(fd, <<byte_size(encoded)::32, crc::32>> <> encoded)
  end

  defp read_log_entry(fd) do
    case :file.read(fd, 8) do
      {:ok, <<len::32, crc::32>>} ->
        case :file.read(fd, len) do
          {:ok, bin} ->
            if :erlang.crc32(bin) == crc, do: :erlang.binary_to_term(bin), else: {:corrupt, :crc_mismatch}
          _ -> :error
        end
      _ -> :eof
    end
  end

  # ----------------------
  # Mnesia Offsets
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
    key = "#{user}_#{device_id}_#{partition_id}"

    case :mnesia.transaction(fn ->
           case :mnesia.read(:device_offsets, key) do
             [rec] ->
               {:device_offsets, _key, _user, _device_id, _partition_id, offset} = rec
               offset
             [] ->
               :mnesia.write({:device_offsets, key, user, device_id, partition_id, 0})
               0
           end
         end) do
      {:atomic, offset} -> offset
      {:aborted, _} -> 0
    end
  end

  defp set_device_offset(user, device_id, partition_id, offset) do
    key = "#{user}_#{device_id}_#{partition_id}"
    :mnesia.transaction(fn ->
      :mnesia.write({:device_offsets, key, user, device_id, partition_id, offset})
    end)
  end

  # ----------------------
  # Debug helpers
  # ----------------------
  def show_current_segments do
    case :mnesia.transaction(fn ->
          :mnesia.match_object({:current_segment, :_, :_ , :_})
        end) do
      {:atomic, results} ->
        Enum.map(results, fn {:current_segment, user, partition_id, seg} ->
          %{user: user, partition_id: partition_id, segment: seg}
        end)

      {:aborted, reason} -> {:error, reason}
    end
  end
end



# BimipQueue.write("user1",2,"alice_2","bob","Hello Bob!")
# BimipQueue.write("user2",2,"alice_2","bob","Hello Bob!")
# # BimipQueue.fetch_unacked("user1", "alice_2", 2)
# BimipLog.list_device_offsets()

# ✅ Key Improvements
# Sparse indexing: Only writes to index every @index_granularity messages (default 1000).
# Device offsets fixed: Uses :mnesia.match_object/1 to correctly read offsets.
# Fetch respects last read offset: No duplicates anymore.
# Efficient seek: Uses :gb_trees.prev/2 to jump to the nearest sparse index position.


# BimipLog.write("user1", 1, "alice", "bob", "Hello Bob!")
# BimipLog.fetch("user1", "device_2", 1)

# Enum.each(1..10, fn i ->
#   BimipLog.write("user1", 1, "alice", "bob", "Msg #{i}")
# end)

# BimipLog.write("user3", 1, "alice", "bob", "Msg")

# BimipLog.purge_old_segments("user1", 1)
# BimipLog.write("user1", 1, "alice", "bob", "Msg ")
# BimipLog.purge_segments_by_time("user1", 1)

# BimipLog.show_current_segments()


# Enum.each(1..500, fn i ->
#   payload = String.duplicate("HelloWorld", 1024 * 1024)  # ~10 MB per message
#   BimipLog.write("user1", 1, "alice", "bob", "payload")
# end)

# BimipLog.write("user1", 1, "alice", "bob", "payload")
# BimipLog.fetch("user1", "alice_1", 1, 10)


# Enum.each(1..100, fn _ ->
#   BimipLog.write("user1", 1, "alice", "bob", "payload")
# end)

