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

    # Roll over segment if needed
    {:ok, stat} = File.stat(qfile)
    if stat.size >= @segment_size_limit do
      new_seg = seg + 1
      set_current_segment(user, partition_id, new_seg)
      File.touch(queue_file(user, partition_id, new_seg))
      IO.puts("✅ Segment rolled over: #{seg} → #{new_seg}")
    end

    # Update sparse index every N messages (20-byte entries)
    if rem(next_offset, @index_granularity) == 0 do
      append_index_file(user, partition_id, seg, next_offset, pos_before)
    end

    # Update next offset (persist)
    update_next_offset(user, partition_id, next_offset + 1)

    {:ok, next_offset}
  end

  @doc """
  Fetch messages for a user/device from a specific partition,
  properly aligned to device offsets.
  Returns:
    {:ok, %{
       messages: [...],
       device_offset: last_offset_read,
       target_offset: target_offset,
       current_segment: current_seg,
       first_segment: first_seg
     }}
  """
  def fetch(user, device_id, partition_id, limit \\ 10) do
    ensure_files_exist!(user, partition_id)
    ensure_device_files_exist!(user, device_id, partition_id)

    # 1️⃣ Device last offset
    last_offset = get_device_offset(user, device_id, partition_id)
    target_offset = last_offset + 1

    # 2️⃣ Current/first segments
    current_seg = get_current_segment(user, partition_id)
    first_seg = get_first_segment(user, partition_id)

    # 3️⃣ Sparse index lookup (fixed 20-byte entries)
    {_indexed_offset, start_seg, start_pos} = lookup_sparse_index(user, partition_id, target_offset)

    # 4️⃣ Iterate segments
    {messages, last_offset_read} =
      Enum.reduce_while(start_seg..current_seg, {[], last_offset}, fn seg, {acc, last} ->
        qfile = queue_file(user, partition_id, seg)

        if not File.exists?(qfile) do
          {:cont, {acc, last}}
        else
          read_segment(qfile, target_offset, acc, last, limit)
        end
      end)

    # 5️⃣ Update device offset
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
  # current_segment table: records like {:current_segment, {user, partition_id}, seg}
  defp get_current_segment(user, partition_id) do
    key = {user, partition_id}

    case :mnesia.transaction(fn -> :mnesia.read(:current_segment, key) end) do
      {:atomic, [{:current_segment, ^key, seg}]} -> seg
      {:atomic, []} ->
        :mnesia.transaction(fn -> :mnesia.write({:current_segment, key, 1}) end)
        1

      {:aborted, reason} ->
        Logger.error("Failed reading current_segment: #{inspect(reason)}")
        1
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
  # device_offsets table records: {:device_offsets, {user, device_id, partition_id}, offset}
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
  # first_segment table records: {:first_segment, {user, partition_id}, seg}
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
  # index_file stores raw binary records back-to-back
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

      _ ->
        {0, 1, 0}
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

      _ ->
        :eof
    end
  end

  # ----------------------
  # Next offsets per {user, partition_id} (Mnesia)
  # Table records: {:next_offsets, {user, partition_id}, offset}
  # ----------------------
  defp get_next_offset(user, partition_id) do
    key = {user, partition_id}

    case :mnesia.transaction(fn -> :mnesia.read(:next_offsets, key) end) do
      {:atomic, [{:next_offsets, ^key, offset}]} -> offset
      {:atomic, []} ->
        :mnesia.transaction(fn -> :mnesia.write({:next_offsets, key, 1}) end)
        1

      {:aborted, reason} ->
        Logger.error("get_next_offset aborted: #{inspect(reason)}")
        1
    end
  end

  defp update_next_offset(user, partition_id, offset) do
    key = {user, partition_id}
    :mnesia.transaction(fn -> :mnesia.write({:next_offsets, key, offset}) end)
  end

  # ----------------------
  # Segment reader
  # ----------------------
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
end


# BimipLog.write("user1", 1, "alice", "bob", "payload1")
# BimipLog.fetch("user1", "alice", 1, 2)
