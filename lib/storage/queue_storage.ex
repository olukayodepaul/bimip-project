defmodule QueueStorage do
  @moduledoc """
  Offline queue system per `{eid, channel}` with append-only logs.

  ## Tables (must exist)
  1. `:queuing_index` (queue metadata)
     - key: `{eid, channel}`  
     - fields:  
       - `msg_ids` → list of message IDs in order  
       - `offset` → last fetched/acked index  

  2. `:queue` (actual messages)
     - key: `{eid, msg_id}`  
     - fields: `payload`, `timestamp`
  """

  ## --------------------
  ## Insert message (O(1) append)
  ## --------------------
  def insert(eid, channel, payload) do
    :mnesia.transaction(fn ->
      key_index = {eid, channel}

      case :mnesia.read(:queuing_index, key_index) do
        [] ->
          # first message
          msg_id = 1
          :mnesia.write({:queue, {eid, msg_id}, payload, DateTime.utc_now()})
          :mnesia.write({:queuing_index, key_index, [msg_id], 0})
          {:ok, msg_id}

        [{:queuing_index, ^key_index, msg_ids, offset}] ->
          # append new msg_id to tail
          msg_id = (List.last(msg_ids) || 0) + 1
          :mnesia.write({:queue, {eid, msg_id}, payload, DateTime.utc_now()})
          :mnesia.write({:queuing_index, key_index, msg_ids ++ [msg_id], offset})
          {:ok, msg_id}
      end
    end)
  end

  ## --------------------
  ## Fetch messages (FIFO batch, O(1) head-tail slice)
  ## --------------------
  def fetch(eid, channel, limit \\ 10, batch_size \\ 2) do
    # Read the queue_index outside parallel tasks
    [{:queuing_index, {^eid, ^channel}, msg_ids, offset}] =
      :mnesia.transaction(fn -> :mnesia.read(:queuing_index, {eid, channel}) end)
      |> case do
        {:atomic, []} -> []
        {:atomic, [record]} -> [record]
        {:aborted, _} -> []
      end

    # Slice next messages
    to_fetch_ids = Enum.slice(msg_ids, offset, limit)
    if to_fetch_ids == [], do: [], else: fetch_batches(eid, to_fetch_ids, batch_size)
  end

  defp fetch_batches(eid, to_fetch_ids, batch_size) do
    batches = Enum.chunk_every(to_fetch_ids, batch_size)

    batches
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
      max_concurrency: 2,
      timeout: :infinity
      )
      |> Enum.flat_map(fn {:ok, results} -> results end)
  end

  # Fetch the current state of the queue_index for an eid and channel
  def fetch_queue_index(eid, channel) do
    case :mnesia.transaction(fn -> :mnesia.read(:queuing_index, {eid, channel}) end) do
      {:atomic, []} ->
        {:error, :no_queue}

      {:atomic, [{:queuing_index, {^eid, ^channel}, msg_ids, last_offset}]} ->
        max_id = List.last(msg_ids) || 0
        {:ok, %{last_offset: last_offset, max_id: max_id, total_ids: msg_ids}}
    end
  end

  # Update the last_offset and max_id after a batch fetch
  def update_queue_index(eid, channel, new_offset, max_id) do
    :mnesia.transaction(fn ->
      case :mnesia.read(:queuing_index, {eid, channel}) do
        [] -> :noop
        [{:queuing_index, {^eid, ^channel}, msg_ids, _old_offset}] ->
          # Remove already-fetched messages from head
          pruned_msg_ids = Enum.drop(msg_ids, new_offset)
          :mnesia.write({:queuing_index, {eid, channel}, pruned_msg_ids, new_offset})
          :ok
      end
    end)
  end

  # Fetch the current state of the queue_index for an eid and channel
  def fetch_queue_index(eid, channel) do
    :mnesia.transaction(fn ->
      case :mnesia.read(:queuing_index, {eid, channel}) do
        [] -> {0, 0}
        [{:queuing_index, {^eid, ^channel}, msg_ids, last_offset}] ->
          max_id = List.last(msg_ids) || 0
          {last_offset, max_id}
      end
    end)
    |> case do
      {:atomic, result} -> result
      _ -> {0, 0}
    end
  end

  # Update the last_offset and max_id after a batch fetch
  def update_queue_index(eid, channel, new_offset) do
    :mnesia.transaction(fn ->
      case :mnesia.read(:queuing_index, {eid, channel}) do
        [] -> :noop
        [{:queuing_index, {^eid, ^channel}, msg_ids, _old_offset}] ->
          :mnesia.write({:queuing_index, {eid, channel}, msg_ids, new_offset})
          :ok
      end
    end)
  end

end


# QueueStorage.fetch_queue_index("user123", :sub)
# QueueStorage.update_queue_index("user123", :sub, 2)
# eid, channel, new_offset, new_max_id