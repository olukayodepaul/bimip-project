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
      from: %{eid: from_eid},
      device: device,
      signal_offset: signal_offset,
      user_offset: user_offset

  } = payload) do

    queue_id = "#{from_eid}_#{to_eid}"
    ack_state = Injection.get_ack_status(queue_id, device, @partition_id, signal_offset)
    reply =  send_signal_to_sender(id, signal_offset, user_offset, @status, payload.from, payload.to, true, ack_state)

    reply
    |> ThrowSignalSchema.success()
    |> then(&SignalCommunication.outbouce(payload.from, &1))

  end

  def device(%Chat.SignalStruct{
      id: id,
      to: %{eid: to_eid},
      from: %{eid: from_eid},
      device: device,
      signal_offset: signal_offset,
      user_offset: user_offset
  } = payload) do

    queue_id = "#{from_eid}_#{to_eid}"

    {:ok, _adv_offset} = Injection.advance_offset(queue_id, device, @partition_id, signal_offset)
    ack_state = Injection.get_ack_status(queue_id, device, @partition_id, signal_offset)
    reply = send_signal_to_sender(id, signal_offset, user_offset, @status, payload.from, payload.to, true, ack_state)

    reply
    |> ThrowSignalSchema.success()
    |> then(&SignalCommunication.outbouce(payload.from, &1))

  end

  def receiver(%Chat.SignalStruct{
        id: id,
        to: %{eid: to_eid, connection_resource_id: to_device_id},
        from: %{eid: from_eid, connection_resource_id: from_device_id},
        device: device,
        signal_offset: signal_offset,
        user_offset: user_offset,
        signal_lifecycle_state: signal_lifecycle_state
    } = payload) do

    queue_id = "#{from_eid}_#{to_eid}"          # A → B queue (sender queue)
    reverse_queue_id = "#{to_eid}_#{from_eid}"  # B → A queue (receiver queue)
    ack_atom = String.to_existing_atom(signal_lifecycle_state)

    with {:atomic, _} <- Injection.mark_ack_status(queue_id, from_device_id, @partition_id, signal_offset, ack_atom),
        {:atomic, _} <- Injection.mark_ack_status(reverse_queue_id, to_device_id, @partition_id, user_offset, ack_atom) do

        case ack_atom do
          :read -> IO.inspect(:read)
          :delivered ->

            with {:ok, _ } <- Injection.advance_offset(queue_id, from_device_id, @partition_id, signal_offset) do

              # 1.  receiver send to it self first
              ack_state = Injection.get_ack_status(queue_id, device, @partition_id, signal_offset)
              reply = send_signal_to_sender(id, signal_offset, user_offset, 1, payload.from, payload.to, true, ack_state)

              # receiver send to is other online device by filtering it self
              # send to sender genserver while genserver send to other devices......

              reply
                |> ThrowSignalSchema.success()
                |> then(&SignalCommunication.outbouce(payload.from, &1))

            else
                error ->
                IO.inspect(error, label: "Receiver ACK failed")
                {:error, error}
            end

          :sent -> :ok
        end

    else
      error ->
        IO.inspect(error, label: "Receiver ACK failed")
        {:error, error}
    end
  end

  defp send_signal_to_sender(id, offset, user_offset, status, from, to, advance_offset,  %{sent: sent, delivered: delivered, read: read}) do
    %{
      id: id,
      signal_offset: offset,
      user_offset: user_offset,
      status: status,
      from: from,
      to: from,
      signal_type: 1,
      signal_ack_state: %{send: sent, received: delivered, read: read, advance_offset: advance_offset},
      signal_request: 1
    }
  end


end
