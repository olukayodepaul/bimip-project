defmodule Chat.SendMessage do

  alias Queue.Injection
  alias Route.{SignalCommunication, Connect}

  @partition_id  1
  @sender_signal_type  1
  @receiver_signal_type  1
  @status 1
  @sender_push_type 2
  @receiver_push_type 3
  @signal_request 2

  def store_message({
    %{eid: from_eid, connection_resource_id: from_device_id} = from,
    %{eid: to_eid, connection_resource_id: to_device_id} = to,
    id, payload},
    state
    ) do

    queue_id = "#{from_eid}_#{to_eid}"
    reverse_queue_id = "#{to_eid}_#{from_eid}"

    # The 'with' block is now much cleaner, focusing only on the outcome of the steps.
    with {:ok, offset} <- store_and_ack_sender(payload, queue_id, from, to, from_device_id),
        {:ok, recv_offset} <- store_and_ack_receiver(payload, reverse_queue_id, from, to, from_device_id)
      do

        send_signal_to_sender(id, offset, @status, from, to)

        payload
        |> set_message_fields(offset, offset, @sender_push_type, queue_id, from_device_id, to_eid)
        |> send_message_to_sender_other_devices

        payload
        |> set_message_fields(recv_offset, offset, @receiver_push_type, reverse_queue_id, to_device_id, from_eid)
        |> Connect.send_message_to_receiver_server

      else
        {:error, reason} ->
          Logger.error("Message pipeline failed: #{inspect(reason)}")
      end

    {:noreply, state}
  end

  defp store_and_ack_sender(payload, queue_id, from, to, from_device_id) do
    storage_payload =
      payload
      |> Map.put(:signal_type, @sender_signal_type)
      |> Map.put(:device_id, from_device_id)

    with {:ok, offset} <- Injection.store_message(queue_id, @partition_id, from, to, storage_payload),
        {:ok, _adv_offset} <- Injection.advance_offset(queue_id, from_device_id, @partition_id, offset),
        {:atomic, _ack_id} <- Injection.mark_ack_status(queue_id, from_device_id, @partition_id, offset, :sent) do
      {:ok, offset}
    end
  end

  defp store_and_ack_receiver(payload, reverse_queue_id, from, to, from_device_id) do
    storage_payload =
      payload
      |> Map.put(:signal_type, @receiver_signal_type)
      |> Map.put(:device_id, from_device_id)

    with {:ok, recv_offset} <- Injection.store_message(reverse_queue_id, @partition_id, from, to, storage_payload),
        {:atomic, _ack_id} <- Injection.mark_ack_status(reverse_queue_id, from_device_id, @partition_id, recv_offset, :sent) do
      {:ok, recv_offset}
    end
  end

  defp send_message_to_sender_other_devices(new_payload) do
    SignalCommunication.send_message_to_sender_other_devices(new_payload)
  end

  defp set_message_fields(payload, signal_offset, user_offset, signal_type, queue_id, device_id, conversation_owner) do
    payload
    |> Map.put(:signal_request, @signal_request)
    |> Map.put(:signal_offset, signal_offset)
    |> Map.put(:user_offset, user_offset)
    |> Map.put(:signal_type, signal_type)
    |> Map.put(:signal_request, 2)
    |> Map.put(:signal_offset_state, false)
    |> Map.put(:conversation_owner, conversation_owner)
    |> Map.put(:signal_ack_state, Injection.get_ack_status(queue_id, device_id, @partition_id, signal_offset))
  end

  defp send_signal_to_sender(id, offset, status, from, to) do
    %{
        id: id,
        signal_offset: offset,
        user_offset: offset,
        status: status,
        from: from,
        to: to,
        signal_type: 1,
        signal_ack_state: %{sent: false, delivered: false, read: false},
        signal_request: 2
      }
      |> ThrowSignalSchema.success
      |> then(&SignalCommunication.outbouce(from, &1))
  end

end
