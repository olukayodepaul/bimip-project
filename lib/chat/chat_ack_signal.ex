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
    delivered_process_stream_reduce(batched_acks)
  end

  def read_message(%Chat.SignalStruct{batched_acks: batched_acks} = _signal) when is_list(batched_acks) and length(batched_acks) == 0, do: :empty
  def read_message(%Chat.SignalStruct{batched_acks: batched_acks} = _signal) when length(batched_acks) > 0 do
    read_process_stream_reduce(batched_acks)
  end

  defp delivered_send_to_network(key, batch) do

    IO.inspect(batch)

    ack_batch =
      Enum.flat_map(batch, fn item ->
        [
          {item.owners.from, @partition_id, item.user_offset, :delivered},
          {item.owners.to, @partition_id, item.offset, :delivered}
        ]
      end)

      case Queue.Injection.ack_status_multi(ack_batch) do
        {:ok, _commits} ->

          server_route(batch, :eid, :signal_deliver_ack_server, key)
          |> Route.Connect.handle_inbouce_signal()

        {:error, reason} ->
          IO.puts("Failed to update ACKs: #{inspect(reason)}")
      end
    :ok
  end

  defp read_send_to_network(key, batch) do

    IO.inspect(batch)

    ack_batch =
      Enum.flat_map(batch, fn item ->
        [
          {item.owners.from, @partition_id, item.user_offset, :read},
          {item.owners.to, @partition_id, item.offset, :read}
        ]
      end)

      case Queue.Injection.ack_status_multi(ack_batch) do
        {:ok, _commits} ->

          server_route(batch, :eid, :signal_read_ack_server, key)
          |> Route.Connect.handle_inbouce_signal()

        {:error, reason} ->
          IO.puts("Failed to update ACKs: #{inspect(reason)}")
      end
    :ok
  end

  # Async sending wrapper: Reverses the list (to restore original order) and starts the task.
  defp delivered_async_send(key, batch) do
    Task.start(fn ->
      delivered_send_to_network(key, Enum.reverse(batch))
    end)
  end

  defp read_async_send(key, batch) do
    Task.start(fn ->
      read_send_to_network(key, Enum.reverse(batch))
    end)
  end

  def delivered_process_stream_reduce(input_stream) do
    # The accumulator (acc) now stores {count, list} for O(1) length check
    final_acc =
      input_stream
      |> Enum.reduce(%{}, fn item, acc ->
        key = item.owners.from

        {current_count, current_list} = Map.get(acc, key, {0, []})

        new_list = [item | current_list]
        new_count = current_count + 1

        if new_count >= @max_batch do
          delivered_async_send(key, new_list)
          Map.delete(acc, key)
        else
          Map.put(acc, key, {new_count, new_list})
        end
      end)

    final_acc
    |> Enum.each(fn {key, {_count, list}} -> delivered_async_send(key, list) end)
    :ok
  end

  def read_process_stream_reduce(input_stream) do
    # The accumulator (acc) now stores {count, list} for O(1) length check
    final_acc =
      input_stream
      |> Enum.reduce(%{}, fn item, acc ->
        key = item.owners.from

        {current_count, current_list} = Map.get(acc, key, {0, []})

        new_list = [item | current_list]
        new_count = current_count + 1

        if new_count >= @max_batch do
          read_async_send(key, new_list)
          Map.delete(acc, key)
        else
          Map.put(acc, key, {new_count, new_list})
        end
      end)

    final_acc
    |> Enum.each(fn {key, {_count, list}} -> read_async_send(key, list) end)
    :ok
  end

  def advance_contiguous_offset(eid, device, partition, last_process_offset, signal_offset) do
    range = last_process_offset..signal_offset
    advance_offset(eid, device, partition, range)
  end

  defp advance_offset(user, device, partition, offset) do
    Injection.advance_offset(user, device, partition, offset)
  end

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

  defp server_route(payload, chanel, signal_to_server, eid) do
    {chanel, eid, signal_to_server, payload}
  end

end
