defmodule Chat.SendMessage do

  alias Queue.Injection
  alias Route.{SignalCommunication, Connect}

  @partition_id  1
  @sender_signal_type  2
  @receiver_signal_type  3
  @status 1
  @signal_request 2

  def store_message({
    %{eid: from_eid, connection_resource_id: from_device_id} = from,
    %{eid: to_eid, connection_resource_id: to_device_id} = to,
    id, payload},
    state
    ) do

    queue_id = "#{from_eid}_#{to_eid}"
    reverse_queue_id = "#{to_eid}_#{from_eid}"

    case get_message_offset(queue_id, from_device_id, @partition_id, "jvnjdvnjdsfnv") do
      {:ok, ft_offset} ->

        send_signal_to_sender(id, ft_offset, @status, from, to, queue_id, from_device_id, @partition_id)

      {:error, :not_found} ->
        with {:ok, offset} <- store_and_ack_sender(payload, queue_id, from, to, from_device_id),
            {:ok, recv_offset} <- store_and_ack_receiver(payload, reverse_queue_id, from, to, from_device_id) do

          send_signal_to_sender(id, offset, @status, from, to, queue_id, from_device_id, @partition_id)
          insert_message_id(queue_id, from_device_id, @partition_id, id, offset)

          payload
          |> set_message_fields(offset, offset, @sender_signal_type, queue_id, from_device_id)
          |> send_message_to_sender_other_devices

          payload
          |> set_message_fields(recv_offset, offset, @receiver_signal_type, reverse_queue_id, to_device_id)
          |> Connect.send_message_to_receiver_server

        else
          {:error, reason} ->
            Logger.error("Message pipeline failed: #{inspect(reason)}")
        end
    end

    {:noreply, state}
  end

  defp store_and_ack_sender(payload, queue_id, from, to, from_device_id) do
    with {:ok, offset} <- Injection.store_message(queue_id, @partition_id, from, to, payload),
        {:ok, _adv_offset} <- Injection.advance_offset(queue_id, from_device_id, @partition_id, offset),
        {:atomic, _ack_id} <- Injection.mark_ack_status(queue_id, from_device_id, @partition_id, offset, :sent) do
      {:ok, offset}
    end
  end

  defp store_and_ack_receiver(payload, reverse_queue_id, from, to, from_device_id) do
    with {:ok, recv_offset} <- Injection.store_message(reverse_queue_id, @partition_id, from, to, payload),
        {:atomic, _ack_id} <- Injection.mark_ack_status(reverse_queue_id, from_device_id, @partition_id, recv_offset, :sent) do
      {:ok, recv_offset}
    end
  end

  defp send_message_to_sender_other_devices(new_payload) do
    SignalCommunication.send_message_to_sender_other_devices(new_payload)
  end

  defp get_message_offset(user, device, partition, message_id) do
    Injection.get_message_offset(user, device, partition, message_id)
  end

  defp insert_message_id(user, device, partition, message_id, offset) do
    Injection.insert_message_id(user, device, partition, message_id, offset)
  end

  def get_ack_status(user, device, partition, offset) do
    Injection.get_ack_status(user, device, partition, offset)
  end

  def confirm_advance_offset(user, device, partition, offset) do
    Injection.confirm_advance_offset(user, device, partition, offset)
  end

  defp set_message_fields(payload, signal_offset, user_offset, signal_type, queue_id, device_id) do
    payload
    |> Map.put(:signal_type, signal_type)
    |> Map.put(:user_offset, user_offset)
    |> Map.put(:signal_offset, signal_offset)
    |> Map.put(:signal_request, @signal_request)
    |> Map.put(:owner, payload.from)
    |> Map.put(:signal_ack_state,  %{send: true, delivered: false, read: false, advance_offset: false})
  end

  defp send_signal_to_sender(id, offset, status, from, to, user, from_device_id, partition_id) do

    %{read: read, sent: sent, delivered: delivered} = get_ack_status(user, from_device_id, partition_id, offset)
    adv = confirm_advance_offset(user, from_device_id, partition_id, offset)

    %{
        id: id,
        signal_offset: offset,
        user_offset: offset,
        status: status,
        from: to,
        to: from,
        signal_type: 1,
        signal_request: 2,
        signal_ack_state: %{send: sent, delivered: delivered, read: read, advance_offset: adv}
      }
      |> ThrowSignalSchema.success
      |> then(&SignalCommunication.outbouce(from, &1))
  end

end
