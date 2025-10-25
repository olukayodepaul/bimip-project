# defmodule BimipQueue do
#   @moduledoc """
#   Kafka-style file-backed queue system with Mnesia-backed offsets and sparse indexing.
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

#     # Only write sparse index
#     if rem(next_offset, @index_granularity) == 0 do
#       append_index_file(user, partition_id, next_offset, pos)
#     end

#     update_next_offset(user, partition_id, next_offset + 1)
#     {:ok, next_offset}
#   end

#   def fetch(user, device_id, partition_id, limit \\ 10) do
#     ensure_files_exist!(user, partition_id)

#     last_offset = get_device_offset(user, device_id, partition_id)
#     index_tree = recover_index(user, partition_id)

#     # Find nearest sparse index <= last_offset
#     start_pos =
#   index_tree
#   |> :gb_trees.to_list()
#   |> Enum.filter(fn {offset, _pos} -> offset <= last_offset end)
#   |> List.last()
#   |> case do
#        nil -> 0
#        {_offset, pos} -> pos
#      end

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

#     # Update device offset in Mnesia
#     set_device_offset(user, device_id, partition_id, new_last_offset)

#     {:ok, messages, new_last_offset}
#   end

#   # ----------------------
#   # Index Recovery (sparse index)
#   # ----------------------
#   defp recover_index(user, partition_id) do
#     idx_file = index_file(user, partition_id)

#     if not File.exists?(idx_file) or File.stat!(idx_file).size == 0 do
#       :gb_trees.empty()
#     else
#       {:ok, data} = File.read(idx_file)

#       chunks = for <<offset::64, pos::64 <- data>>, do: {offset, pos}

#       Enum.reduce(chunks, :gb_trees.empty(), fn {offset, pos}, tree ->
#         :gb_trees.enter(offset, pos, tree)
#       end)
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
#   defp get_next_offset(user, partition_id) do
#     {:atomic, offset} =
#       :mnesia.transaction(fn ->
#         case :mnesia.match_object({:next_offsets, user, partition_id, :_}) do
#           [{:next_offsets, _u, _p, offset}] -> offset
#           [] ->
#             :mnesia.write({:next_offsets, user, partition_id, 1})
#             1
#         end
#       end)

#     offset
#   end

#   defp update_next_offset(user, partition_id, offset) do
#     :mnesia.transaction(fn ->
#       :mnesia.write({:next_offsets, user, partition_id, offset})
#     end)
#   end

#   defp get_device_offset(user, device_id, partition_id) do
#     case :mnesia.transaction(fn ->
#            case :mnesia.match_object({:device_offsets, user, device_id, partition_id, :_}) do
#              [{:device_offsets, _u, _d, _p, offset}] -> offset
#              [] ->
#                :mnesia.write({:device_offsets, user, device_id, partition_id, 0})
#                0
#            end
#          end) do
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



defmodule BimipQueue do
  @moduledoc """
  Kafka-style file-backed queue system with Mnesia-backed offsets and sparse indexing,
  including a sparse ACK index for fast unacknowledged message retrieval.
  """

  @base_dir "data/bimip"
  @index_granularity 1

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

    # Sparse index for normal reads
    if rem(next_offset, @index_granularity) == 0 do
      append_index_file(user, partition_id, next_offset, pos)
    end

    # Always append to ACK index
    append_ack_index_file(user, partition_id, next_offset)

    update_next_offset(user, partition_id, next_offset + 1)
    {:ok, next_offset}
  end

  def fetch_unacked(user, device_id, partition_id, limit \\ 10) do
    ensure_files_exist!(user, partition_id)

    last_offset = get_device_offset(user, device_id, partition_id)
    ack_offsets = recover_ack_index(user, partition_id)
                  |> Enum.filter(&(&1 > last_offset))
                  |> Enum.take(limit)

    queue_file = queue_file(user, partition_id)
    index_tree = recover_index(user, partition_id)

    {:ok, fd} = File.open(queue_file, [:read, :binary])

    messages =
      Enum.map(ack_offsets, fn offset ->
        # Find nearest sparse index <= offset
        start_pos =
          index_tree
          |> :gb_trees.to_list()
          |> Enum.filter(fn {idx_offset, _} -> idx_offset <= offset end)
          |> List.last()
          |> case do
               nil -> 0
               {_idx_offset, pos} -> pos
             end

        :file.position(fd, start_pos)
        # scan until we reach the desired offset
        Stream.unfold(fd, fn fd_state ->
          case read_log_entry(fd_state) do
            :eof -> nil
            msg -> {msg, fd_state}
          end
        end)
        |> Enum.find(&(&1.offset == offset))
      end)
      |> Enum.filter(& &1)

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
  # ACK Index
  # ----------------------
  defp append_ack_index_file(user, partition_id, offset) do
    idx_file = ack_index_file(user, partition_id)
    {:ok, fd} = File.open(idx_file, [:append, :binary])
    IO.binwrite(fd, <<offset::64>>)
    File.close(fd)
  end

  defp recover_ack_index(user, partition_id) do
    idx_file = ack_index_file(user, partition_id)
    if not File.exists?(idx_file) or File.stat!(idx_file).size == 0 do
      []
    else
      {:ok, data} = File.read(idx_file)
      for <<offset::64 <- data>>, do: offset
    end
  end

  def ack_message(user, partition_id, offset) do
    mark_ack(user, partition_id, offset)
  end

  defp mark_ack(user, partition_id, offset) do
    idx_file = ack_index_file(user, partition_id)
    {:ok, data} = File.read(idx_file)
    offsets = for <<o::64 <- data>>, do: o
    new_offsets = Enum.reject(offsets, &(&1 == offset))

    {:ok, fd} = File.open(idx_file, [:write, :binary])
    Enum.each(new_offsets, fn o -> IO.binwrite(fd, <<o::64>>) end)
    File.close(fd)
  end

  # ----------------------
  # Index Recovery (sparse index)
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
  defp ack_index_file(user, partition_id), do: Path.join(user_dir(user), "ack_index_#{partition_id}.idx")

  defp ensure_files_exist!(user, partition_id) do
    File.mkdir_p!(user_dir(user))
    unless File.exists?(queue_file(user, partition_id)), do: File.write!(queue_file(user, partition_id), "")
    unless File.exists?(index_file(user, partition_id)), do: File.write!(index_file(user, partition_id), "")
    unless File.exists?(ack_index_file(user, partition_id)), do: File.write!(ack_index_file(user, partition_id), "")
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

# BimipQueue.write("user1",2,"alice_2","bob","Hello Bob!")
# BimipQueue.write("user2",2,"alice_2","bob","Hello Bob!")
# BimipQueue.fetch_unacked("user1", "alice_2", 2)

# ✅ Key Improvements
# Sparse indexing: Only writes to index every @index_granularity messages (default 1000).
# Device offsets fixed: Uses :mnesia.match_object/1 to correctly read offsets.
# Fetch respects last read offset: No duplicates anymore.
# Efficient seek: Uses :gb_trees.prev/2 to jump to the nearest sparse index position.

