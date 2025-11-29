defmodule Chat.AckSignal do

  alias Queue.Injection

  @partition_id 1
  @status 1

  def ack(%Chat.SignalStruct{signal_type_ex: signal_type_ex} = signal) do
    case signal_type_ex do
      1 -> advance_offset_state(signal)
      2 -> message_ack_state(signal)
      _ -> IO.puts("")
    end
  end

  def advance_offset_state(%Chat.SignalStruct{
    eid: eid,
    device: device,
    signal_offset: signal_offset
  } = _signal) when is_integer(signal_offset) do

    case get_last_seen_offset(eid, device, @partition_id) do
      {:ok, last_process_offset} ->
        if signal_offset > last_process_offset,
          do: advance_contiguous_offset(eid, device, @partition_id, last_process_offset, signal_offset)
        _ ->
          :ok
    end
  end

  def advance_contiguous_offset(eid, device, partition, last_process_offset, signal_offset) do
    range = last_process_offset..signal_offset
    advance_offset(eid, device, partition, range)
  end

  def message_ack_state(%Chat.SignalStruct{} = _signal) do
    IO.inspect("2 advance offset state")
  end


  # ---------------------------------------------------
  # Helpers
  # ---------------------------------------------------
  defp get_last_seen_offset(user, device, partition),
    do: Injection.get_last_seen_offset(user, device, partition)

  defp advance_offset(user, device, partition, offset),
    do: Injection.advance_offset(user, device, partition, offset)

end
