defmodule Chat.AckSignal do
  alias Queue.Injection
  alias Route.SignalCommunication
  alias ThrowSignalSchema

  @partition_id 1
  @status 1

  def ack(%Chat.SignalStruct{} = signal) do

    handlers = %{
      1 => &sender/1,
      2 => &device/1,
      3 => &receiver/1
    }

    signal_type = signal.signal_type

    case Map.get(handlers, signal_type) do
      nil ->
        IO.puts("Unknown signal type: #{signal_type}")

      handler ->
        handler.(signal)
    end
  end

  def sender(%Chat.SignalStruct{
      id: id,
      to: %{eid: to_eid},
      from: %{eid: from_id},
      device: device,
      signal_offset: signal_offset,
      user_offset: user_offset

  } = payload) do

    queue_id = "#{from_id}_#{to_eid}"
    ack_state = Injection.get_ack_status(queue_id, device, @partition_id, signal_offset)
    send_signal_to_sender(id, signal_offset, user_offset, @status, payload.from, payload.to, ack_state)

  end

  def device(%Chat.SignalStruct{
      id: id,
      to: %{eid: to_eid},
      from: %{eid: from_id},
      device: device,
      signal_offset: signal_offset,
      user_offset: user_offset
  } = payload) do

    queue_id = "#{from_id}_#{to_eid}"

    {:ok, _adv_offset} = Injection.advance_offset(queue_id, device, @partition_id, signal_offset)

    ack_state = Injection.get_ack_status(queue_id, device, @partition_id, signal_offset)

    send_signal_to_sender(id, signal_offset, user_offset, @status, payload.from, payload.to,ack_state)
  end

  def receiver(payload) do
    IO.inspect(payload, label: "RECEIVER handler received")
  end

  defp send_signal_to_sender(id, offset, user_offset, status, from, to, %{sent: sent, delivered: delivered, read: read}) do
    %{
      id: id,
      signal_offset: offset,
      user_offset: user_offset,
      status: status,
      from: from,
      to: to,
      signal_type: 1,
      signal_ack_state: %{send: sent, received: delivered, read: read},
      signal_request: 1
    }
    |> ThrowSignalSchema.success()
    |> then(&SignalCommunication.outbouce(from, &1))
  end


end
