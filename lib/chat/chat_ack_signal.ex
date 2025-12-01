defmodule Chat.AckSignal do

  alias Queue.Injection
  alias Route.Connect

  @partition_id 1
  @status 1

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
    process_batch_lazily(batched_acks)
  end

  def process_batch_lazily(batch_list) do
    Stream.unfold(batch_list, fn
      [] ->
        nil

      [head | tail] ->
        processed = process_single_offset(head)
        {processed, tail}
    end)
    |> Stream.run()
    IO.inspect("side effect process completed")
  end

  defp process_single_offset(%Bimip.BatchedOffset{
    owners: %Bimip.OWNERS{from: from_owner},
    user_offset: user_offset,
    offset: offset,
  } = _payload) do
    IO.inspect(from_owner)

    IO.inspect("run")
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
