defmodule Chat.AckSignal do

  alias Queue.Injection
  alias Route.Connect

  @partition_id 1
  @status 1
  @max_batch 50

  def ack(%Chat.SignalStruct{signal_type_ex: signal_type_ex} = signal) do
    case signal_type_ex do
      1 -> advance_offset_state(signal)
      2 -> read_message(signal)
      3 -> deliver_message(signal)
      _ -> IO.puts("")
    end
  end

  def advance_offset_state(%Chat.SignalStruct{
    eid: eid,
    device: device,
    signal_offset: signal_offset
  } = signal) when is_integer(signal_offset) do

    case get_last_seen_offset(eid, device, @partition_id) do
      {:ok, last_process_offset} ->
        if signal_offset > last_process_offset do
          advance_contiguous_offset(eid, device, @partition_id, last_process_offset, signal_offset)
          sender(signal)
        else
          sender(signal)
        end

      {:error, _reason} -> :ok
      _ -> :ok
    end
  end

  def deliver_message(%Chat.SignalStruct{batched_acks: batched_acks} = _signal) when is_list(batched_acks) and length(batched_acks) == 0, do: :empty
  def deliver_message(%Chat.SignalStruct{batched_acks: batched_acks} = _signal) when length(batched_acks) > 0 do
    process_stream_reduce(batched_acks)
  end

  defp send_to_network(_key, batch) do

    ack_batch =
      Enum.flat_map(batch, fn item ->
        [
          {item.owners.from, @partition_id, item.user_offset, :delivered},
          {item.owners.to, @partition_id, item.offset, :delivered}
        ]
      end)

      IO.inspect(ack_batch)
      # case Queue.Injection.ack_status_multi(ack_batch) do
      #   {:ok, commits} ->
      #     IO.inspect(commits, label: "ACK commits")
      #   {:error, reason} ->
      #     IO.puts("Failed to update ACKs: #{inspect(reason)}")
      # end
    :ok
  end

  # Async sending wrapper: Reverses the list (to restore original order) and starts the task.
  defp async_send(key, batch) do
    Task.start(fn ->
      send_to_network(key, Enum.reverse(batch))
    end)
  end

  @doc """
  Processes an input stream using Enum.reduce. Best for memory efficiency
  as it consumes the stream item-by-item without pre-loading.
  """
  def process_stream_reduce(input_stream) do
    # The accumulator (acc) now stores {count, list} for O(1) length check
    final_acc =
      input_stream
      |> Enum.reduce(%{}, fn item, acc ->
        key = item.owners.from

        # 1. Retrieve the current state: {count, list}
        {current_count, current_list} = Map.get(acc, key, {0, []})

        # 2. Update the state (O(1) prepend and O(1) increment)
        new_list = [item | current_list]
        new_count = current_count + 1

        # 3. Check if the batch is full (O(1) check)
        if new_count >= @max_batch do
          # Send the full batch asynchronously
          async_send(key, new_list)

          # Return the accumulator map without the now-sent key/list
          Map.delete(acc, key)
        else
          # Update the accumulator with the growing {count, list} tuple
          Map.put(acc, key, {new_count, new_list})
        end
      end)

    # Flush remaining batches asynchronously
    IO.puts("\n--- Starting final flush tasks (Reduce version)... ---")
    final_acc
    |> Enum.each(fn {key, {_count, list}} -> async_send(key, list) end)

    :ok
  end

  def read_message(%Chat.SignalStruct{} = _signal) do
    IO.inspect("read message")
  end

  def advance_contiguous_offset(eid, device, partition, last_process_offset, signal_offset) do
    range = last_process_offset..signal_offset
    advance_offset(eid, device, partition, range)
  end

  defp advance_offset(user, device, partition, offset) do
    Injection.advance_offset(user, device, partition, offset)
  end

  # ---------------------------------------------------
  # Helpers
  # ---------------------------------------------------
  defp get_last_seen_offset(user, device, partition),
    do: Injection.get_last_seen_offset(user, device, partition)

  def sender(%Chat.SignalStruct{
    eid: eid,
    device: device,
    signal_offset: signal_offset,
    signal_type_ex: signal_type_ex
  } = _signal) when is_integer(signal_offset) do

    date = Until.UniPosTime.uni_pos_time()

    %{
      id: nil,
      signal_offset: signal_offset,
      user_offset: nil,
      status: @status,
      from: %{eid: eid, connection_resource_id: device},
      to: %{eid: eid, connection_resource_id: device},
      signal_type: nil,
      signal_type_ex: signal_type_ex,
      ack: %{
          advance_offset: true, advance_offset_timestamp: date,
          sent: nil, delivered: nil, read: nil, sent_timestamp: nil,
          delivered_timestamp: nil, read_timestamp: nil
        }
    }
    |> ThrowSignalSchema.success()
    |> then(&Connect.outbouce(device, &1))

  end


end
