defmodule Queue.QueueLogImpl do
  @moduledoc """
  BimipLog — Optimized append-only per-user/device log.
  Uses sparse indexing for O(log n) lookups and background compaction for state management.
  """

  require Logger

  @base_dir "data/bimip"
  @index_granularity 1
  @segment_size_limit 104_857_600 # 100 MB
  @entry_header_size 8           # 32bit size + 32bit crc
  @index_entry_size 20           # 64bit offset + 32bit seg + 64bit pos

  alias Queue.Persist

  # -------------------------------------------------------------------
  # Public API: Writing
  # -------------------------------------------------------------------

  def write(user, partition_id, from, to, payload, message_id, sender_offset) do
    with :ok <- ensure_files_exist(user, partition_id),
         {:ok, %{seg: seg, next_offset: next_offset, do_rollover: do_rollover}} <- get_atomic_write_state(user, partition_id) do

      qfile = queue_file(user, partition_id, seg)

      case File.open(qfile, [:append, :binary]) do
        {:ok, fd} ->
          {:ok, pos_before} = :file.position(fd, :eof)
          timestamp = DateTime.utc_now() |> DateTime.to_unix(:millisecond)
          offset_payload = Persist.build(%{payload: payload}, next_offset, sender_offset)

          record = %{
            message_id: message_id,
            device_id: payload.device_id,
            offset: next_offset,
            partition_id: partition_id,
            from: from,
            to: to,
            payload: offset_payload,
            timestamp: timestamp
          }

          result = case write_log_entry(fd, record) do
            :ok ->
              :ok = finalize_write_state(user, partition_id, seg, next_offset, pos_before, do_rollover)
              {:ok, next_offset}
            error -> error
          end
          File.close(fd)
          result
        {:error, reason} -> {:error, reason}
      end
    end
  end

  # -------------------------------------------------------------------
  # Public API: Fetching (Seek Optimized)
  # -------------------------------------------------------------------

  def fetch(user, device_id, partition_id, limit \\ 10) when limit > 0 do
    with :ok <- ensure_files_exist(user, partition_id),
         {:ok, commit_offset} <- get_commit_offset(user, device_id, partition_id),
         {:ok, current_seg} <- get_current_segment(user, partition_id),
         {:ok, first_seg} <- get_first_segment(user, partition_id) do

      target_offset = commit_offset + 1

      # JUMP: Use sparse index to find the starting point
      {_idx_off, start_seg_from_idx, start_pos_from_idx} =
        lookup_sparse_index(user, partition_id, target_offset)

      start_seg = max(start_seg_from_idx, first_seg)

      payload_stream =
        start_seg..current_seg
        |> Stream.flat_map(fn seg ->
          qfile = queue_file(user, partition_id, seg)
          seek_pos = if seg == start_seg, do: start_pos_from_idx, else: 0

          if File.exists?(qfile) do
            # read_ahead avoids disk thrashing during sequential scans
            case File.open(qfile, [:read, :binary, :read_ahead]) do
              {:ok, fd} ->
                read_segment_optimized(fd, seek_pos, target_offset, user, device_id, limit)
                |> tap_close_file(fd)
              _ -> []
            end
          else
            []
          end
        end)
        |> Enum.take(limit)

      {:ok, %{messages: payload_stream, device_offset: commit_offset}}
    end
  end

  # -------------------------------------------------------------------
  # Public API: Compaction (For ACK/State partitions)
  # -------------------------------------------------------------------

  def compact_partition(user, partition_id) do
    {:ok, current_seg} = get_current_segment(user, partition_id)
    {:ok, first_seg} = get_first_segment(user, partition_id)

    # Only compact inactive segments
    if current_seg > first_seg do
      qfile = queue_file(user, partition_id, first_seg)
      compacted_file = qfile <> ".compact"

      # Reduce to latest state per message_id
      latest_entries =
        stream_segment_entries(qfile)
        |> Enum.reduce(%{}, fn msg, acc -> Map.put(acc, msg.message_id, msg) end)

      {:ok, fd} = File.open(compacted_file, [:write, :binary])
      Enum.each(latest_entries, fn {_, record} -> write_log_entry(fd, record) end)
      File.close(fd)

      File.rm(qfile)
      File.rename(compacted_file, qfile)
      Logger.info("Compacted segment #{first_seg} for #{user}/#{partition_id}")
    end
  end

  # -------------------------------------------------------------------
  # Internal: Optimized Reading Logic
  # -------------------------------------------------------------------

  defp read_segment_optimized(fd, seek_pos, target_offset, eid, device_id, limit) do
    :file.position(fd, seek_pos)

    Stream.unfold(0, fn
      count when count >= limit -> nil
      count ->
        case read_log_entry_selective(fd, target_offset, device_id) do
          {:ok, msg} -> {wrap_message(msg, eid, device_id), count + 1}
          :skip -> {0, count} # Marker for skip
          :eof -> nil
          {:corrupt, _} -> nil
        end
    end)
    |> Stream.reject(&(&1 == 0))
  end

  defp read_log_entry_selective(fd, target_offset, device_id) do
    case :file.read(fd, @entry_header_size) do
      {:ok, <<size::32, crc::32>>} ->
        case :file.read(fd, size) do
          {:ok, bin} ->
            if :erlang.crc32(bin) == crc do
              msg = :erlang.binary_to_term(bin)
              # Optimization: Filter here before passing back to stream
              if msg.offset >= target_offset and msg.device_id != device_id, do: {:ok, msg}, else: :skip
            else
              {:corrupt, :crc_mismatch}
            end
          :eof -> :eof
          _ -> {:corrupt, :io_error}
        end
      :eof -> :eof
      _ -> {:corrupt, :io_error}
    end
  end

  defp wrap_message(msg, eid, device_id) do
    %Bimip.Message{
      msg |
      to: %Bimip.Identity{eid: eid, connection_resource_id: device_id},
      timestamp: DateTime.utc_now() |> DateTime.to_unix(:millisecond),
      type: if(msg.from.eid == eid, do: 2, else: 3)
    }
  end

  # -------------------------------------------------------------------
  # Internal: Log Helpers
  # -------------------------------------------------------------------

  defp write_log_entry(fd, record) do
    data = :erlang.term_to_binary(record)
    crc = :erlang.crc32(data)
    IO.binwrite(fd, <<byte_size(data)::32, crc::32, data::binary>>)
  end

  defp read_log_entry(fd) do
    case :file.read(fd, @entry_header_size) do
      {:ok, <<size::32, crc::32>>} ->
        case :file.read(fd, size) do
          {:ok, bin} ->
            if :erlang.crc32(bin) == crc, do: {:ok, :erlang.binary_to_term(bin)}, else: {:corrupt, :crc_mismatch}
          :eof -> :eof
          _ -> {:corrupt, :io_error}
        end
      :eof -> :eof
      _ -> {:corrupt, :io_error}
    end
  end

  defp stream_segment_entries(path) do
    Stream.resource(
      fn -> File.open!(path, [:read, :binary]) end,
      fn fd ->
        case read_log_entry(fd) do
          {:ok, msg} -> {[msg], fd}
          _ -> {:halt, fd}
        end
      end,
      fn fd -> File.close(fd) end
    )
  end

  # -------------------------------------------------------------------
  # Atomic State & Indexing
  # -------------------------------------------------------------------

  defp get_atomic_write_state(user, partition_id) do
    :mnesia.transaction(fn ->
      key = {user, partition_id}
      curr = case :mnesia.read(:current_segment, key) do
        [{_, _, s}] -> s
        [] -> 1
      end
      off = case :mnesia.read(:next_offsets, key) do
        [{_, _, o}] -> o
        [] -> 1
      end

      qfile = queue_file(user, partition_id, curr)
      do_roll = case File.stat(qfile) do
        {:ok, %{size: s}} when s >= @segment_size_limit -> true
        _ -> false
      end

      :mnesia.write({:next_offsets, key, off + 1})
      %{seg: (if do_roll, do: curr + 1, else: curr), next_offset: off, do_rollover: do_roll}
    end)
    |> case do
      {:atomic, map} -> {:ok, map}
      _ -> {:error, :mnesia_fail}
    end
  end

  defp finalize_write_state(user, pid, seg, offset, pos, rollover) do
    if rollover do
      set_current_segment(user, pid, seg + 1)
      # Trigger background compaction for non-data logs
      if !String.contains?(pid, "data"), do: spawn(fn -> compact_partition(user, pid) end)
    end
    if rem(offset, @index_granularity) == 0, do: append_index_file(user, pid, seg, offset, pos)
    :ok
  end

  # -------------------------------------------------------------------
  # Path & Metadata Helpers
  # -------------------------------------------------------------------

  defp queue_file(u, p, s), do: Path.join([@base_dir, u, "queue_#{p}_#{s}.log"])
  defp index_file(u, p), do: Path.join([@base_dir, u, "index_#{p}.idx"])
  defp ensure_files_exist(u, _), do: File.mkdir_p(Path.join(@base_dir, u))

  defp get_commit_offset(u, d, p) do
    case :mnesia.dirty_read(:commit_offsets, {u, d, p}) do
      [{_, _, o}] -> {:ok, o}
      [] -> {:ok, 0}
    end
  end

  defp set_current_segment(u, p, s), do: :mnesia.dirty_write({:current_segment, {u, p}, s})
  defp get_current_segment(u, p) do
    case :mnesia.dirty_read(:current_segment, {u, p}) do
      [{_, _, s}] -> {:ok, s}
      [] -> {:ok, 1}
    end
  end
  defp get_first_segment(u, p) do
    case :mnesia.dirty_read(:first_segment, {u, p}) do
      [{_, _, s}] -> {:ok, s}
      [] -> {:ok, 1}
    end
  end

  defp append_index_file(user, pid, seg, offset, pos) do
    idx = index_file(user, pid)
    {:ok, fd} = File.open(idx, [:append, :binary])
    IO.binwrite(fd, <<offset::64, seg::32, pos::64>>)
    File.close(fd)
  end

  defp lookup_sparse_index(user, pid, target) do
    idx = index_file(user, pid)
    case File.stat(idx) do
      {:ok, %{size: s}} when s >= @index_entry_size ->
        {:ok, fd} = File.open(idx, [:read, :binary])
        res = binary_search_index_fd(fd, target, 0, div(s, @index_entry_size) - 1, {0, 1, 0})
        File.close(fd)
        res
      _ -> {0, 1, 0}
    end
  end

  defp binary_search_index_fd(fd, target, low, high, best) when low > high, do: best
  defp binary_search_index_fd(fd, target, low, high, best) do
    mid = div(low + high, 2)
    :file.position(fd, mid * @index_entry_size)
    case :file.read(fd, @index_entry_size) do
      {:ok, <<offset::64, seg::32, pos::64>>} ->
        cond do
          offset == target -> {offset, seg, pos}
          offset < target -> binary_search_index_fd(fd, target, mid + 1, high, {offset, seg, pos})
          true -> binary_search_index_fd(fd, target, low, mid - 1, best)
        end
      _ -> best
    end
  end

  defp tap_close_file(stream, fd) do
    Stream.resource(fn -> stream end, fn s ->
      case Enum.split(s, 1) do
        {[], _} -> {:halt, s}
        {[h], t} -> {[h], t}
      end
    end, fn _ -> File.close(fd) end)
  end
end
