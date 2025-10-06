defmodule QueueStorage do
  @moduledoc """
  Offline queue system per `{eid, channel}` with append-only logs using plain lists.
  
  Tables (must exist):
  1. `:queuing_index` – stores queue metadata: `[msg_ids]` and `offset`.
  2. `:queue` – stores actual messages by `{eid, msg_id}`.
  """
  alias Settings.Queue

  @max_queue_size Queue.max_queue_size() # max messages to keep per queue, adjust as needed

  ## --------------------
  ## Insert message (append to list, prune old)
  ## --------------------
  def insert(eid, channel, payload) do
    :mnesia.transaction(fn ->
      key_index = {eid, channel}

      case :mnesia.read(:queuing_index, key_index) do
        [] ->
          msg_id = 1
          :mnesia.write({:queue, {eid, msg_id}, payload, DateTime.utc_now()})
          :mnesia.write({:queuing_index, key_index, [msg_id], 0})
          {:ok, msg_id}

        [{:queuing_index, ^key_index, msg_ids, offset}] ->
          msg_id = (List.last(msg_ids) || 0) + 1
          :mnesia.write({:queue, {eid, msg_id}, payload, DateTime.utc_now()})
          new_ids = msg_ids ++ [msg_id]

          prune_if_needed(eid, key_index, new_ids, offset)
          {:ok, msg_id}
      end
    end)
  end

  ## --------------------
  ## Internal prune function
  ## --------------------
  defp prune_if_needed(eid, key_index, msg_ids, offset) do
    if length(msg_ids) > @max_queue_size do
      prune_count = length(msg_ids) - @max_queue_size
      {to_prune, kept_ids} = Enum.split(msg_ids, prune_count)

      # Delete pruned messages from :queue
      for old_id <- to_prune do
        :mnesia.delete({:queue, {eid, old_id}})
      end

      # Update queue_index with kept IDs and adjusted offset
      new_offset = max(0, offset - prune_count)
      :mnesia.write({:queuing_index, key_index, kept_ids, new_offset})
    else
      # No pruning needed
      :mnesia.write({:queuing_index, key_index, msg_ids, offset})
    end
  end

  ## --------------------
  ## Fetch messages (FIFO)
  ## --------------------
  def fetch(eid, channel, limit \\ 10, batch_size \\ 1) do
    case fetch_queue_index(eid, channel) do
      {:ok, %{last_offset: last_offset, total_ids: msg_ids}} ->
        start_index = max(0, last_offset - (List.first(msg_ids) || 0))
        to_fetch_ids = Enum.slice(msg_ids, start_index, limit)

        if to_fetch_ids == [] do
          []
        else
          %{
            payload: fetch_batches(eid, to_fetch_ids, batch_size),
            last_offset: List.last(to_fetch_ids)
          }
        end

      {:error, _} ->
        []
    end
  end

  ## --------------------
  ## Fetch batch of messages
  ## --------------------
  defp fetch_batches(eid, to_fetch_ids, batch_size) do
    Enum.chunk_every(to_fetch_ids, batch_size)
    |> Task.async_stream(
      fn batch ->
        :mnesia.activity(:transaction, fn ->
          match_spec =
            for msg_id <- batch do
              {{:queue, {eid, msg_id}, :_, :_}, [], [:"$_"]}
            end

          Enum.flat_map(match_spec, &(:mnesia.select(:queue, [&1])))
        end)
      end,
      max_concurrency: 4,
      timeout: :infinity
    )
    |> Enum.flat_map(fn {:ok, results} -> results end)
  end

  ## --------------------
  ## Fetch queue index
  ## --------------------
  def fetch_queue_index(eid, channel) do
    case :mnesia.transaction(fn -> :mnesia.read(:queuing_index, {eid, channel}) end) do
      {:atomic, []} -> {:error, :no_queue}
      {:atomic, [{:queuing_index, {^eid, ^channel}, msg_ids, last_offset}]} ->
        {:ok, %{last_offset: last_offset, total_ids: msg_ids}}
    end
  end

  ## --------------------
  ## Update queue index after fetch
  ## --------------------
  def update_queue_index(eid, channel, new_offset) do
    :mnesia.transaction(fn ->
      case :mnesia.read(:queuing_index, {eid, channel}) do
        [] -> :noop
        [{:queuing_index, _key_index, msg_ids, _old_offset}] ->
          pruned_ids = Enum.drop(msg_ids, new_offset)

          # Delete already-fetched messages
          for msg_id <- Enum.take(msg_ids, new_offset), do: :mnesia.delete({:queue, {eid, msg_id}})

          :mnesia.write({:queuing_index, {eid, channel}, pruned_ids, new_offset})
          :ok
      end
    end)
  end

  ## --------------------
  ## Ack messages
  ## --------------------
  def ack(eid, channel, up_to_msg_id, prune \\ true) do
    :mnesia.transaction(fn ->
      key_index = {eid, channel}

      case :mnesia.read(:queuing_index, key_index) do
        [] -> :noop
        [{:queuing_index, ^key_index, msg_ids, offset}] ->
          idx = Enum.find_index(msg_ids, fn id -> id == up_to_msg_id end)
          new_offset = if idx, do: max(offset, idx + 1), else: offset

          remaining_ids =
            if prune and new_offset > 0 do
              to_delete = Enum.take(msg_ids, new_offset)
              for msg_id <- to_delete, do: :mnesia.delete({:queue, {eid, msg_id}})
              Enum.drop(msg_ids, new_offset)
            else
              msg_ids
            end

          :mnesia.write({:queuing_index, key_index, remaining_ids, new_offset})
          :ok
      end
    end)
  end

  ## --------------------
  ## Check if queue has data
  ## --------------------
  def queue_has_data?(eid, channel) do
    case fetch_queue_index(eid, channel) do
      {:ok, %{total_ids: ids}} -> ids != []
      _ -> false
    end
  end
end


# QueueStorage.fetch("user123", :sub)
# QueueStorage.fetch_queue_index("user123", :sub)
# QueueStorage.update_queue_index("user123", :sub, 10)
# QueueStorage.update_queue_index("user123", :sub, 5, 0)
# QueueStorage.queue_has_data?()
# eid, channel, new_offset, new_max_id
# QueueStorage.insert("user123", :sub, %{body: "hello"})
