defmodule Chat.SendMessage do

  alias Queue.Injection
  alias Route.{SignalCommunication, Connect}

  @partition_id  1
  @sender_signal_type  1
  @receiver_signal_type  1
  @status 1

  def store_message({
    %{eid: from_eid, connection_resource_id: from_device_id} = from,
    %{eid: to_eid, connection_resource_id: to_device_id} = to,
    id, payload},
    state
    ) do

    queue_id = "#{from_eid}_#{to_eid}"
    reverse_queue_id = "#{to_eid}_#{from_eid}"

    with {:ok, offset} <-
          payload
          |> Map.put(:signal_type, @sender_signal_type)
          |> Map.put(:device_id, from_device_id)
          |> then(&Injection.store_message(queue_id, @partition_id, from, to, &1)),

          {:ok, adv_offset} <- Injection.advance_offset(queue_id, from_device_id, @partition_id, offset),
          {:atomic, ack_id} <- Injection.mark_ack_status(queue_id, from_device_id, @partition_id, offset, :sent),

          {:ok, recv_offset} <-
          payload
          |> Map.put(:signal_type, @receiver_signal_type)
          |> Map.put(:device_id, from_device_id)
          |> then(&Injection.store_message(reverse_queue_id, @partition_id, from, to, &1)),

          {:atomic, ack_id} <- Injection.mark_ack_status(reverse_queue_id, from_device_id, @partition_id, recv_offset, :sent)
      do

        send_signal_to_sender({from, to, @status, offset, id})

        # Push message to other device
        payload
        |> Map.put(:signal_offset, offset)
        |> Map.put(:user_offset, offset)
        |> Map.put(:signal_type, 2)
        |> Map.put(:signal_offset_state, false)
        |> Map.put(:signal_ack_state, Injection.get_ack_status(queue_id, from_device_id, @partition_id, offset))
        |> send_message_to_sender_other_devices

        # Push messsage to receiver
        payload
        |> Map.put(:signal_offset, recv_offset)
        |> Map.put(:user_offset, offset)
        |> Map.put(:signal_offset_state, false)
        |> Map.put(:signal_type, 3)
        |> Map.put(:signal_ack_state, Injection.get_ack_status(reverse_queue_id, to_device_id, @partition_id, recv_offset))
        |> Connect.send_chat

      else
        {:error, reason} ->
          Logger.error("Message pipeline failed: #{inspect(reason)}")
      end

    {:noreply, state}
  end

  def send_signal_to_sender({from, to, status,  offset, id}) do
    binary_payload = ThrowSignalSchema.success(from, to, status, offset,offset,id)
    SignalCommunication.single_signal_communication(from, binary_payload)
  end

  def send_message_to_sender_other_devices(new_payload) do
    SignalCommunication.single_signal_message(new_payload)
  end

end
