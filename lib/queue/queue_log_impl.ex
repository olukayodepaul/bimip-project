defmodule Queue.QueueLogImpl do
  @moduledoc """
  BimipLog — append-only per-user/device log with per-device pending ACKs.

  Features:
    - File-backed segments with sparse index
    - Per-device pending ACKs (MapSet) to avoid full log scans
    - Commit offsets advanced to the highest acknowledged offset
    - Supports millions of users/devices efficiently
  """

  require Logger

  @base_dir "data/bimip"
  @index_granularity 1
  @segment_size_limit 104_857_600 # 100 MB
  @entry_header_size 8           # FIX: 32bit size + 32bit crc for log entries
  @index_entry_size 20           # FIX: 64bit offset + 32bit seg + 64bit pos for index
  alias Queue.Persist

  # ----------------------
  # Public API
  # ----------------------

  @doc "Append a message to a user's partition log"
  def write(user, partition_id, from, to, payload, message_id,  user_offset \\ nil, merge_offset \\ nil) do
    with :ok <- ensure_files_exist(user, partition_id),
        {:ok, %{seg: seg, next_offset: next_offset, do_rollover: do_rollover}} <- get_atomic_write_state(user, partition_id) do

      qfile = queue_file(user, partition_id, seg)


      case File.open(qfile, [:append, :binary]) do
        {:ok, fd} ->
          {:ok, pos_before} = :file.position(fd, :eof)

          timestamp = DateTime.utc_now() |> DateTime.to_unix(:millisecond)
          offset_payload = Persist.build(%{from: from, to: to, payload: payload}, next_offset, user_offset)

          record = %{
            message_id: message_id,
            device_id: payload.device_id,
            offset: next_offset,
            merge_offset: merge_offset || 0,
            partition_id: partition_id,
            from: from,
            to: to,
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

  def fetch(user, device_id, partition_id, limit \\ 10) when limit > 0 do
    with :ok <- ensure_files_exist(user, partition_id),
        :ok <- ensure_device_files_exist(user, device_id, partition_id),
        {:ok, commit_offset} <- get_commit_offset(user, device_id, partition_id),
        {:ok, current_seg} <- get_current_segment(user, partition_id),
        {:ok, first_seg} <- get_first_segment(user, partition_id) do

      target_offset = commit_offset + 1
      {_indexed_offset, start_seg_from_idx, start_pos_from_idx} =
        lookup_sparse_index(user, partition_id, target_offset)

      start_seg = max(start_seg_from_idx, first_seg)

      # Lazy stream across segments
      payload_stream =
        start_seg..current_seg
        |> Stream.flat_map(fn seg ->
          qfile = queue_file(user, partition_id, seg)

          if File.exists?(qfile) do
            case File.open(qfile, [:read, :binary]) do
              {:ok, fd} ->
                start_pos = if seg == start_seg, do: start_pos_from_idx, else: 0

                read_segment_from_fd_lazy(fd, start_pos, target_offset, user, device_id, limit)
                |> Stream.take(limit) # limit per fetch
                |> tap_close_file(fd)

              {:error, reason} ->
                Logger.error("Failed to open segment file #{qfile}: #{inspect(reason)}")
                []
            end
          else
            []
          end
        end)
        |> Enum.take(limit) # materialize batch

      {:ok,
        %{
          messages: payload_stream,
          device_offset: commit_offset,
          target_offset: target_offset,
          current_segment: current_seg,
          first_segment: first_seg
        }}
    else
      {:error, reason} -> {:error, reason}
    end
  end

  defp read_segment_from_fd_lazy(fd, start_pos, target_offset, eid, device_id, limit) do
    :file.position(fd, start_pos)

    Stream.unfold({fd, 0}, fn
      {fd_state, count} when count < limit ->
        case read_log_entry(fd_state) do
          :eof -> nil
          {:corrupt, _} -> nil
          {:ok, msg} ->
            if msg.offset >= target_offset and msg.device_id != device_id do
              {{msg.offset, msg.payload}, {fd_state, count + 1}}
            else
              {nil, {fd_state, count}}
            end
        end

      _ ->
        nil
    end)
    |> Stream.reject(&is_nil/1)
    |> Stream.map(fn {_offset, msg} ->
      intended_to = %Bimip.Identity{
        eid: eid,
        connection_resource_id: device_id,
        node: nil,
        __unknown_fields__: []
      }

      %Bimip.Message{
        msg |
        to: intended_to,
        timestamp: Until.UniPosTime.uni_pos_time(),
        signal_type: if msg.from.eid == eid do 2 else 3 end
      }
    end)
  end


  # ----------------------
  # Helper to close file after stream processing
  # ----------------------
  defp tap_close_file(stream, fd) do
    Stream.resource(
      fn -> stream end,
      fn
        s ->
          case Enum.split(s, 1) do
            {[], _} -> {:halt, s}
            {[h], t} -> {[h], t}
          end
      end,
      fn _ -> File.close(fd) end
    )
  end

  # ----------------------
  # Atomic write helpers
  # ----------------------
  def get_atomic_write_state(user, partition_id) do
    case :mnesia.transaction(fn ->
      current_seg =
        case :mnesia.read(:current_segment, {user, partition_id}) do
          [{:current_segment, {^user, ^partition_id}, seg}] -> seg
          [] -> 1
        end

      next_offset =
        case :mnesia.read(:next_offsets, {user, partition_id}) do
          [{:next_offsets, {^user, ^partition_id}, offset}] -> offset
          [] -> 1
        end

      qfile = queue_file(user, partition_id, current_seg)
      do_rollover =
        case File.stat(qfile) do
          {:ok, stat} when stat.size >= @segment_size_limit -> true
          _ -> false
        end

      :mnesia.write({:next_offsets, {user, partition_id}, next_offset + 1})

      new_seg = if do_rollover, do: current_seg + 1, else: current_seg

      # Return a single {:ok, map}
      %{seg: new_seg, next_offset: next_offset, do_rollover: do_rollover}
    end) do
      {:atomic, map} -> {:ok, map}
      {:aborted, reason} -> {:error, {:mnesia_aborted, reason}}
    end
  end

  defp finalize_write_state(user, partition_id, current_seg, offset, pos_before, do_rollover) do
    if do_rollover do
      new_seg = current_seg + 1
      set_current_segment(user, partition_id, new_seg)
      File.touch(queue_file(user, partition_id, new_seg))
    end

    if rem(offset, @index_granularity) == 0 do
      append_index_file(user, partition_id, current_seg, offset, pos_before)
    end

    :ok
  end

  # ----------------------
  # Segment helpers
  # ----------------------
  defp get_current_segment(user, partition_id) do
    key = {user, partition_id}
    case :mnesia.transaction(fn -> :mnesia.read(:current_segment, key) end) do
      {:atomic, [{:current_segment, ^key, seg}]} -> {:ok, seg}
      {:atomic, []} -> {:ok, 1}
      {:aborted, reason} -> {:error, reason}
    end
  end

  defp get_first_segment(user, partition_id) do
    key = {user, partition_id}
    case :mnesia.transaction(fn -> :mnesia.read(:first_segment, key) end) do
      {:atomic, [{:first_segment, ^key, seg}]} -> {:ok, seg}
      {:atomic, []} -> {:ok, 1}
      {:aborted, reason} -> {:error, reason}
    end
  end

  defp set_current_segment(user, partition_id, seg) do
    key = {user, partition_id}
    :mnesia.transaction(fn -> :mnesia.write({:current_segment, key, seg}) end)
  end

  # ----------------------
  # Commit offsets
  # ----------------------
  def get_commit_offset(user, device_id, partition_id) do
    key = {user, device_id, partition_id}
    case :mnesia.transaction(fn -> :mnesia.read(:commit_offsets, key) end) do
      {:atomic, [{:commit_offsets, ^key, offset}]} -> {:ok, offset}
      {:atomic, []} -> {:ok, 0}
      {:aborted, reason} -> {:error, reason}
    end
  end

  # ----------------------
  # Sparse index helpers
  # ----------------------
  defp queue_file(user, partition_id, seg), do: Path.join(user_dir(user), "queue_#{partition_id}_#{seg}.log")
  defp user_dir(user), do: Path.join(@base_dir, user)
  defp index_file(user, partition_id), do: Path.join(user_dir(user), "index_#{partition_id}.idx")
  defp ensure_files_exist(user, _partition_id), do: File.mkdir_p(user_dir(user))
  defp ensure_device_files_exist(_user, _device, _partition), do: :ok

  defp append_index_file(user, partition_id, seg, offset, pos) do
    idx_file = index_file(user, partition_id)
    case File.open(idx_file, [:append, :binary]) do
      {:ok, fd} ->
        :ok = IO.binwrite(fd, <<offset::64, seg::32, pos::64>>)
        File.close(fd)
        :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp lookup_sparse_index(user, partition_id, target_offset) do
    idx = index_file(user, partition_id)

    case File.stat(idx) do
      {:ok, %{size: size}} when size >= @index_entry_size -> # Used constant
        entries = div(size, @index_entry_size)  # Used constant
        case File.open(idx, [:read, :binary]) do
          {:ok, fd} ->
            res = binary_search_index_fd(fd, target_offset, 0, entries - 1, {0, 1, 0})
            File.close(fd)
            res
          {:error, _} -> {0, 1, 0}
        end

      _ -> {0, 1, 0}  # index file doesn't exist or empty
    end
  end

  defp binary_search_index_fd(_fd, _target, low, high, best) when low > high, do: best
  defp binary_search_index_fd(fd, target_offset, low, high, best) do
    mid = div(low + high, 2)
    pos = mid * @index_entry_size # Used constant
    case :file.position(fd, pos) do
      {:ok, _} ->
        case :file.read(fd, @index_entry_size) do # Used constant
          {:ok, <<offset::64, seg::32, pos64::64>>} ->
            cond do
              offset == target_offset -> {offset, seg, pos64}
              offset < target_offset -> binary_search_index_fd(fd, target_offset, mid + 1, high, {offset, seg, pos64})
              offset > target_offset -> binary_search_index_fd(fd, target_offset, low, mid - 1, best)
            end
          _ -> best
        end
      _ -> best
    end
  end
  # ----------------------
  # Log entry serialization
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
    case :file.read(fd, @entry_header_size) do # Used constant
      {:ok, <<size::32, crc::32>>} ->
        case :file.read(fd, size) do
          {:ok, bin} ->
            if :erlang.crc32(bin) == crc, do: {:ok, :erlang.binary_to_term(bin)}, else: {:corrupt, :crc_mismatch}
          :eof -> :eof
          {:error, reason} -> {:corrupt, reason} # Safety fix
        end
      :eof -> :eof
      {:error, reason} -> {:corrupt, reason} # Safety fix
    end
  end

  # -------------------------------------------------------------------
  # Acknowledge (commit) message offset — moves contiguous commit forward
  # Supports single offset or range
  # -------------------------------------------------------------------
  def ack_message(user, device, partition, offset_or_range) do
    key = {user, device, partition}

    offsets =
      case offset_or_range do
        %Range{} = r -> Enum.to_list(r)
        offset when is_integer(offset) -> [offset]
      end

    result =
      :mnesia.transaction(fn ->
        # Get current commit offset
        commit =
          case :mnesia.read(:commit_offsets, key) do
            [{:commit_offsets, ^key, c}] -> c
            [] -> 0
          end

        # Get current pending set
        pending =
          case :mnesia.read(:pending_acks, key) do
            [{:pending_acks, ^key, set}] -> set
            [] -> MapSet.new()
          end

        # Merge offsets into pending in a single pass
        new_pending = Enum.reduce(offsets, pending, fn off, acc ->
          if off > commit, do: MapSet.put(acc, off), else: acc
        end)

        # Advance commit forward if contiguous
        new_commit = advance_commit_to_max(new_pending, commit)
        remaining = MapSet.filter(new_pending, fn x -> x > new_commit end)

        # Persist
        :mnesia.write({:commit_offsets, key, new_commit})
        :mnesia.write({:pending_acks, key, remaining})

        new_commit
      end)

    case result do
      {:atomic, commit} -> {:ok, commit}
      {:aborted, reason} -> {:error, reason}
    end
  end

  defp advance_commit_to_max(pending, commit) do
    next = commit + 1

    if MapSet.member?(pending, next) do
      # Move commit forward and continue
      advance_commit_to_max(MapSet.delete(pending, next), next)
    else
      # Return the highest contiguous commit
      commit
    end
  end

  def ack_status(user, _device, partition, offset_or_range, status)
      when status in [:sent, :delivered, :read] do

    key = {user, partition}
    offsets =
      case offset_or_range do
        %Range{} = r -> Enum.to_list(r)
        offset when is_integer(offset) -> [offset]
      end

    result =
      :mnesia.transaction(fn -> # FIX: The entire operation is now atomic
        if status == :read do
          # Execute sent and delivered updates first, atomically
          handle_status_ack(key, offsets, :pending_sent, :commit_sent)
          handle_status_ack(key, offsets, :pending_delivered, :commit_delivered)
        end

        {pending_table, commit_table} = case status do
          :sent -> {:pending_sent, :commit_sent}
          :delivered -> {:pending_delivered, :commit_delivered}
          :read -> {:pending_read, :commit_read}
        end

        handle_status_ack(key, offsets, pending_table, commit_table)
      end)

    case result do
      {:atomic, commit} -> {:ok, commit}
      {:aborted, reason} -> {:error, reason}
    end
  end

  defp handle_status_ack(key, offsets, pending_table, commit_table) do
    pending = case :mnesia.read(pending_table, key) do
      [{^pending_table, ^key, set}] -> set
      [] -> MapSet.new()
    end

    commit = case :mnesia.read(commit_table, key) do
      [{^commit_table, ^key, c}] -> c
      [] -> 0
    end

    new_pending = Enum.reduce(offsets, pending, &MapSet.put(&2, &1))
    new_commit = advance_contiguous_to_max(new_pending, commit)
    remaining = MapSet.filter(new_pending, &(&1 > new_commit))

    :mnesia.write({commit_table, key, new_commit})
    :mnesia.write({pending_table, key, remaining})
    new_commit
  end


  defp advance_contiguous_to_max(pending, commit) do
    next = commit + 1
    if MapSet.member?(pending, next), do: advance_contiguous_to_max(MapSet.delete(pending, next), next), else: commit
  end

  def message_status(user, _device, partition, offset) do
    # key = {user, device, partition}
    key = {user,  partition}

    {:ok, sent_commit} =
      case :mnesia.transaction(fn ->
        case :mnesia.read(:commit_sent, key) do
          [{:commit_sent, ^key, c}] -> c
          [] -> 0
        end
      end) do
        {:atomic, c} -> {:ok, c}
        _ -> {:ok, 0}
      end

    {:ok, delivered_commit} =
      case :mnesia.transaction(fn ->
        case :mnesia.read(:commit_delivered, key) do
          [{:commit_delivered, ^key, c}] -> c
          [] -> 0
        end
      end) do
        {:atomic, c} -> {:ok, c}
        _ -> {:ok, 0}
      end

    {:ok, read_commit} =
      case :mnesia.transaction(fn ->
        case :mnesia.read(:commit_read, key) do
          [{:commit_read, ^key, c}] -> c
          [] -> 0
        end
      end) do
        {:atomic, c} -> {:ok, c}
        _ -> {:ok, 0}
      end

    {:ok, pending_sent} =
      case :mnesia.transaction(fn ->
        case :mnesia.read(:pending_sent, key) do
          [{:pending_sent, ^key, s}] -> s
          [] -> MapSet.new()
        end
      end) do
        {:atomic, s} -> {:ok, s}
        _ -> {:ok, MapSet.new()}
      end

    {:ok, pending_delivered} =
      case :mnesia.transaction(fn ->
        case :mnesia.read(:pending_delivered, key) do
          [{:pending_delivered, ^key, s}] -> s
          [] -> MapSet.new()
        end
      end) do
        {:atomic, s} -> {:ok, s}
        _ -> {:ok, MapSet.new()}
      end

    {:ok, pending_read} =
      case :mnesia.transaction(fn ->
        case :mnesia.read(:pending_read, key) do
          [{:pending_read, ^key, s}] -> s
          [] -> MapSet.new()
        end
      end) do
        {:atomic, s} -> {:ok, s}
        _ -> {:ok, MapSet.new()}
      end

    %{
      sent: offset <= sent_commit or MapSet.member?(pending_sent, offset),
      delivered: offset <= delivered_commit or MapSet.member?(pending_delivered, offset),
      read: offset <= read_commit or MapSet.member?(pending_read, offset)
    }
  end

  def confirm_adv_offset?(user, device, partition, offset) do
    key = {user, device, partition}

    :mnesia.transaction(fn ->
      commit =
        case :mnesia.read(:commit_offsets, key) do
          [{:commit_offsets, ^key, c}] -> c
          [] -> 0
        end

      pending =
        case :mnesia.read(:pending_acks, key) do
          [{:pending_acks, ^key, set}] -> set
          [] -> MapSet.new()
        end

      # True if offset is <= commit (contiguous) OR is in pending ACKs
      offset <= commit or MapSet.member?(pending, offset)
    end)
    |> case do
      {:atomic, result} -> result
      {:aborted, _} -> false
    end
  end

  def insert_message_id(snd_id, rec_id, partition_id, message_id, snd_offset, rec_offset) do
    snd_key = {snd_id, partition_id, message_id}
    rec_key = {rec_id, partition_id, message_id}

    :mnesia.transaction(fn ->
      # Check for existing sender key
      case :mnesia.read(:message_offset, snd_key) do
        [{:message_offset, ^snd_key, _}] ->
          :mnesia.abort({:exists, :sender})
        [] ->
          :ok
      end

      # Check for existing receiver key
      case :mnesia.read(:message_offset, rec_key) do
        [{:message_offset, ^rec_key, _}] ->
          :mnesia.abort({:exists, :receiver})
        [] ->
          :ok
      end

      # If both keys do not exist → insert both
      :mnesia.write({:message_offset, snd_key, snd_offset})
      :mnesia.write({:message_offset, rec_key, rec_offset})

      {:ok, :inserted}
    end)
    |> case do
      {:atomic, result} -> result
      {:aborted, reason} -> {:error, reason}
    end
  end


  def get_message_offset(user,  partition_id, message_id) do
    key = {user,  partition_id, message_id}

    :mnesia.transaction(fn ->
      case :mnesia.read(:message_offset, key) do
        [{:message_offset, ^key, offset}] -> {:ok, offset}
        [] -> {:error, :not_found}
      end
    end)
    |> case do
      {:atomic, result} -> result
      {:aborted, reason} -> {:error, reason}
    end
  end

  def get_last_seen_offset(user, device, partition_id) do
    key = {user, device, partition_id}

    :mnesia.transaction(fn ->
      case :mnesia.read(:commit_offsets, key) do
        [{:commit_offsets, ^key, offset}] -> offset
        [] -> 0
      end
    end)
    |> case do
      {:atomic, offset} -> {:ok, offset}
      {:aborted, reason} -> {:error, reason}
    end
  end

  def ack_message_batched(user, device, partition, offset_or_range, batch_size \\ 1_000) do
    key = {user, device, partition}

    offsets_stream =
      case offset_or_range do
        %Range{} = r -> Stream.chunk_every(Enum.to_list(r), batch_size)
        offset when is_integer(offset) -> [[offset]]
      end

    Enum.reduce_while(offsets_stream, {:ok, 0}, fn batch, {:ok, _last_commit} ->
      case :mnesia.transaction(fn ->
        # Get current commit offset
        commit =
          case :mnesia.read(:commit_offsets, key) do
            [{:commit_offsets, ^key, c}] -> c
            [] -> 0
          end

        # Get current pending set
        pending =
          case :mnesia.read(:pending_acks, key) do
            [{:pending_acks, ^key, set}] -> set
            [] -> MapSet.new()
          end

        # Merge batch offsets safely
        new_pending =
          Enum.reduce(batch, pending, fn off, acc ->
            if off > commit, do: MapSet.put(acc, off), else: acc
          end)

        # Advance commit
        new_commit = advance_commit_to_max(new_pending, commit)
        remaining = MapSet.filter(new_pending, fn x -> x > new_commit end)

        # Persist
        :mnesia.write({:commit_offsets, key, new_commit})
        :mnesia.write({:pending_acks, key, remaining})

        new_commit
      end) do
        {:atomic, commit} -> {:cont, {:ok, commit}}
        {:aborted, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

end
