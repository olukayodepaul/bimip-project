# defmodule ChatMessage.ReceivedSignal do

#   use Queue.QueueLog,
#     base_dir: "data/myqueue",
#     index_granularity: 10,
#     segment_size_limit: 50_000_000

#   alias ThrowSignalSchema

#   def handle_received_signal(
#         %{signal_offset: signal_offset, user_offset: user_offset,
#           from: %{eid: from_eid, connection_resource_id: from_device_id},
#           to: %{eid: to_eid}} = _payload,
#         state
#       ) do
#     receiver_key = "#{from_eid}_#{to_eid}"
#     sender_key = "#{to_eid}_#{from_eid}"
#     partition = 1

#     move_receiver_offset_forward({receiver_key, signal_offset, from_device_id, partition})
#     acknowledge_receiver({receiver_key, signal_offset, partition})
#     acknowledge_sender({sender_key, user_offset, partition})

#     {:noreply, state}
#   end

#   def acknowledge_receiver({user_key, offset, partition}) do
#     ack_status(user_key, "", partition, offset, :delivered)
#   end

#   def acknowledge_sender({user_key, offset, partition}) do
#     ack_status(user_key, "", partition, offset, :delivered)
#   end

#   def move_receiver_offset_forward({user_key, offset, device_id, partition}) do
#     ack_message(user_key, device_id, partition, offset)
#   end

#   def fetch_ack(user_key, offset, partition) do
#     message_status(user_key, "", partition, offset)
#   end
# end
