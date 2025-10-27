defmodule BimipLog do
  require Logger

  @base_dir "data/bimip"
  @index_granularity 1
  @segment_size_limit 50 # in bytes for demo, adjust for real usage

  # ----------------------
  # Public API
  # ----------------------
  def write(user, partition_id, from, to, payload) do
    ensure_files_exist!(user, partition_id)

    seg = get_current_segment(user, partition_id)
    qfile = queue_file(user, partition_id, seg)

    {:ok, fd} = File.open(qfile, [:append, :binary])
    {:ok, pos_before} = :file.position(fd, :eof)

    next_offset = get_next_offset(user, partition_id)
    timestamp = DateTime.utc_now() |> DateTime.to_unix(:millisecond)

    record = %{
      offset: next_offset,
      partition_id: partition_id,
      from: from,
      to: to,
      payload: payload,
      timestamp: timestamp
    }

    write_log_entry(fd, record)
    File.close(fd)

    {:ok, stat} = File.stat(qfile)
    if stat.size >= @segment_size_limit do
      new_seg = seg + 1
      set_current_segment(user, partition_id, new_seg)
      File.touch(queue_file(user, partition_id, new_seg))
      IO.puts("✅ Segment rolled over: #{seg} → #{new_seg}")
    end

    if rem(next_offset, @index_granularity) == 0 do
      append_index_file(user, partition_id, seg, next_offset, pos_before)
    end

    update_next_offset(user, partition_id, next_offset + 1)
    {:ok, next_offset}
  end

  def fetch(user, device_id, partition_id, limit \\ 10) do
    ensure_files_exist!(user, partition_id)
    ensure_device_files_exist!(user, device_id, partition_id)

    last_offset = get_commit_offset(user, device_id, partition_id)
    target_offset = last_offset + 1

    current_seg = get_current_segment(user, partition_id)
    first_seg = get_first_segment(user, partition_id)

    {_indexed_offset, start_seg, _start_pos} = lookup_sparse_index(user, partition_id, target_offset)

    {messages, last_offset_read} =
      Enum.reduce_while(start_seg..current_seg, {[], last_offset}, fn seg, {acc, last} ->
        qfile = queue_file(user, partition_id, seg)
        if not File.exists?(qfile), do: {:cont, {acc, last}}, else: read_segment(qfile, target_offset, acc, last, limit)
      end)

    set_device_offset(user, device_id, partition_id, last_offset_read)

    {:ok,
     %{
       messages: messages,
       device_offset: last_offset_read,
       target_offset: target_offset,
       current_segment: current_seg,
       first_segment: first_seg
     }}
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
      {:aborted, _} -> 1
    end
  end

  defp set_current_segment(user, partition_id, seg) do
    key = {user, partition_id}
    :mnesia.transaction(fn -> :mnesia.write({:current_segment, key, seg}) end)
  end

  defp queue_file(user, partition_id, seg),
    do: Path.join(user_dir(user), "queue_#{partition_id}_#{seg}.log")

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
      {:aborted, _} -> 0
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

  defp ensure_files_exist!(user, _partition_id), do: File.mkdir_p!(user_dir(user))

  defp ensure_device_files_exist!(user, device_id, partition_id) do
    offset_file = device_offset_file(user, device_id, partition_id)
    idx_file = device_index_file(user, device_id, partition_id)
    unless File.exists?(offset_file), do: File.write!(offset_file, :erlang.term_to_binary(%{offset: 0}))
    unless File.exists?(idx_file), do: File.write!(idx_file, "")
  end

  defp device_index_file(user, device_id, partition_id),
    do: Path.join(user_dir(user), "index_#{device_id}_#{partition_id}.idx")

  defp device_offset_file(user, device_id, partition_id),
    do: Path.join(user_dir(user), "offset_#{device_id}_#{partition_id}.dat")

  # ----------------------
  # Sparse index (20 bytes: offset::64, seg::32, pos::64)
  # ----------------------
  defp append_index_file(user, partition_id, seg, offset, pos) do
    idx_file = index_file(user, partition_id)
    {:ok, fd} = File.open(idx_file, [:append, :binary])
    IO.binwrite(fd, <<offset::64, seg::32, pos::64>>)
    File.close(fd)
  end

  defp lookup_sparse_index(user, partition_id, target_offset) do
    idx_file = index_file(user, partition_id)
    case File.read(idx_file) do
      {:ok, bin} when byte_size(bin) >= 20 ->
        total_entries = div(byte_size(bin), 20)
        binary_search_index(bin, target_offset, 0, total_entries - 1, {0, 1, 0})
      _ -> {0, 1, 0}
    end
  end

  defp binary_search_index(_bin, _target_offset, low, high, best) when low > high, do: best
  defp binary_search_index(bin, target_offset, low, high, best) do
    mid = div(low + high, 2)
    <<offset::64, seg::32, pos::64>> = :binary.part(bin, mid * 20, 20)

    cond do
      offset == target_offset -> {offset, seg, pos}
      offset < target_offset -> binary_search_index(bin, target_offset, mid + 1, high, {offset, seg, pos})
      offset > target_offset -> binary_search_index(bin, target_offset, low, mid - 1, best)
    end
  end

  # ----------------------
  # Log helpers
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

  defp read_segment(qfile, target_offset, acc, last, limit) do
    {:ok, fd} = File.open(qfile, [:read, :binary])
    try do
      if acc == [], do: :file.position(fd, 0)
      msgs =
        Stream.unfold(fd, fn fd_state ->
          case read_log_entry(fd_state) do
            :eof -> nil
            {:corrupt, _} -> nil
            msg -> {msg, fd_state}
          end
        end)
        |> Stream.filter(fn m -> m.offset >= target_offset end)
        |> Enum.take(limit - length(acc))

      new_acc = acc ++ msgs
      new_last =
        case List.last(msgs) do
          nil -> last
          msg -> msg.offset
        end

      if length(new_acc) >= limit, do: {:halt, {new_acc, new_last}}, else: {:cont, {new_acc, new_last}}
    after
      File.close(fd)
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
  # ACK table
  # ----------------------
  def ack_message(user, device_id, partition_id, offset) do
    key = {user, device_id, partition_id, offset}
    :mnesia.transaction(fn -> :mnesia.write({:ack_table, key, true}) end)
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
  # Commit offsets
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

  defp commit_ack(user, device_id, partition_id, offset) do
    last_committed = get_commit_offset(user, device_id, partition_id)
    next_to_commit = last_committed + 1

    if offset >= next_to_commit do
      new_offset = advance_commit(user, device_id, partition_id, next_to_commit)
      set_commit_offset(user, device_id, partition_id, new_offset)
    end
  end

  defp advance_commit(user, device_id, partition_id, offset) do
    if acked?(user, device_id, partition_id, offset) do
      advance_commit(user, device_id, partition_id, offset + 1)
    else
      offset - 1
    end
  end

  # ----------------------
  # Helper: ensure table exists
  # ----------------------
  defp ensure_table(table, opts) do
    case :mnesia.table_info(table, :attributes) do
      :undefined -> :mnesia.create_table(table, opts)
      _ -> :ok
    end
  end
end





# ```elixir
# {:ok, offset1} = BimipLog.write("alice", 1, "bob", "alice", "Hello 1")
# {:ok, offset2} = BimipLog.write("alice", 1, "bob", "alice", "Hello 2")
# {:ok, offset3} = BimipLog.write("alice", 1, "bob", "alice", "Hello 3")
# IO.inspect({offset1, offset2, offset3})
# ```

# ---

# ### 3️⃣ Fetch Messages (simulate a device)

# ```elixir
# {:ok, fetch1} = BimipLog.fetch("alice", "device_1", 1, 10)
# IO.inspect(fetch1)
# ```

# * `device_offset` should initially be **0**.
# * Messages returned should start from offset **1** (committed offset + 1).

# ---

# ### 4️⃣ ACK Messages

# ```elixir
# BimipLog.ack_message("alice", "device_1", 1, 1)
# BimipLog.ack_message("alice", "device_1", 1, 2)
# ```

# * After these, `commit_offsets` should advance to **2**.

# ```elixir
# BimipLog.get_commit_offset("alice", "device_1", 1)
# # Should return 2
# ```

# ---

# ### 5️⃣ Fetch Again (only uncommitted messages)

# ```elixir
# {:ok, fetch2} = BimipLog.fetch("alice", "device_1", 1, 10)
# IO.inspect(fetch2)
# ```

# * Should **skip already committed messages**, returning only **offset 3**.

# ---

# ### 6️⃣ ACK Last Message

# ```elixir
# BimipLog.ack_message("alice", "device_1", 1, 3)
# BimipLog.get_commit_offset("alice", "device_1", 1)
# # Should now return 3
# ```

# ---

# ### 7️⃣ Verify ACK Table

# ```elixir
# BimipLog.acked?("alice", "device_1", 1, 1) # true
# BimipLog.acked?("alice", "device_1", 1, 2) # true
# BimipLog.acked?("alice", "device_1", 1, 3) # true
# ```

