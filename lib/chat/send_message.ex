defmodule Chat.SendMessage do

  alias Queue.Injection
  alias Route.SignalCommunication

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
        send_message_to_sender_other_devices()
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

  def send_signal_to_sender_other_devices() do
    AwarenessFanOut.send_direct_message(
QueueLog.message_status(user_a, "", 1, signal_offset_a),
      from_eid, signal_offset_a, signal_offset_a, sender_payload, from_device_id, signal_type
    )
  end



end


# Injection.fetch_messages("a@domain.com_b@domain.com", "aaaaa1", 1, 10)



#     case Injection.write(queue_id, partition_id, from, to, sender_payload) do
#       {:ok, signal_offset_a} ->

#         QueueLog.ack_message(user_a, from_device_id, 1, signal_offset_a)
#         QueueLog.ack_status(user_a, "", 1, signal_offset_a, :sent)

#         receiver_payload = Map.merge(payload, %{
#           signal_type: 3,
#           device_id:  from_device_id
#         })

#         case QueueLog.write(user_b, partition_id, from, to, receiver_payload, signal_offset_a) do
#           {:ok, signal_offset_b} ->

#
#             QueueLog.ack_status(user_b, "", 1, signal_offset_b, :sent)
#             AwarenessFanOut.pair_fan_out({pair_fan_out, from_device_id, from_eid})

#             AwarenessFanOut.send_direct_message(
#               QueueLog.message_status(user_a, "", 1, signal_offset_a),
#               from_eid, signal_offset_a, signal_offset_a, sender_payload, from_device_id, signal_type
#             )

#             transport =  Map.merge(receiver_payload, %{
#               signal_offset: signal_offset_b,
#               user_offset: signal_offset_a,
#               signal_offset_state: false,
#               signal_ack_state: QueueLog.message_status(user_b, "", 1, signal_offset_b)
#             })

#             RegistryHub.send_chat(transport)

#           {:error, reason} ->
#             IO.inspect(reason, label: "[WRITE ERROR B ← A]")
#         end

#       {:error, reason} ->
#         IO.inspect(reason, label: "[WRITE ERROR A → B]")
#     end


# Queue.Injection.fetch_messages("a@domain.com_b@domain.com", "aaaaa1", 1, 10)
# Queue.Injection.get_ack_status("b@domain.com_a@domain.com", "device1", 1, 4)
# Queue.Injection.fetch_messages("a@domain.com_b@domain.com", "aaaaa1", 1, 10)
# Queue.Injection.get_ack_status("b@domain.com_a@domain.com", "device1", 1, 4)
