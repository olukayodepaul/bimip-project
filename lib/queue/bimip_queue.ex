defmodule BimipQueue do
  @moduledoc """
  Kafka-style file-backed queue system with sparse indexing
  and Mnesia-backed device offsets.
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

    # Sparse index: only write every @index_granularity messages
    if rem(next_offset, @index_granularity) == 0 do
      append_index_file(user, partition_id, next_offset, pos)
    end

    update_next_offset(user, partition_id, next_offset + 1)
    {:ok, next_offset}
  end

  def fetch(user, device_id, partition_id, limit \\ 10) do
    ensure_files_exist!(user, partition_id)

    limit = if is_integer(limit), do: limit, else: String.to_integer(limit)
    last_offset = get_device_offset(user, device_id, partition_id)

    # Recover sparse index
    index_tree = recover_index(user, partition_id)

    # Find nearest previous offset in index
    start_pos =
      case :gb_trees.iterator_from(last_offset + 1, index_tree) |> :gb_trees.next() do
        :none ->
          # If no greater offset, use last index in tree
          case :gb_trees.to_list(index_tree) |> List.last() do
            nil -> 0
            {_offset, pos} -> pos
          end
        {{_offset, pos}, _} -> pos
      end

    queue_file = queue_file(user, partition_id)

    case File.open(queue_file, [:read, :binary]) do
      {:ok, fd} ->
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

      {:error, reason} ->
        IO.inspect(reason, label: "File Open Error")
        {:error, reason}
    end
  end

  # ----------------------
  # Sparse Index Recovery
  # ----------------------
  defp recover_index(user, partition_id) do
    idx_file = index_file(user, partition_id)

    if not File.exists?(idx_file) or File.stat!(idx_file).size == 0 do
      :gb_trees.empty()
    else
      {:ok, data} = File.read(idx_file)

      chunks = for <<offset::64, pos::64 <- data>>, do: {offset, pos}

      Enum.reduce(chunks, :gb_trees.empty(), fn {offset, pos}, tree ->
        :gb_trees.enter(offset, pos, tree)
      end)
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
        case :mnesia.match_object({:device_offsets, user, device_id, partition_id, :_}) do
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



# BimipQueue.write("user1",1,"alice","bob","Hello Bob!")
# BimipQueue.write("user2",2,"alice_2","bob","Hello Bob!")
# BimipQueue.fetch("user2","alice_2",2)



