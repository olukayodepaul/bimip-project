defmodule ChatMessage.RecivedSignal do

  alias BimipLog
  
  def received_signal(%{ 
    id: id, 
    signal_offset: signal_offset, 
    user_offset: user_offset,
    status: status,
    from: %{eid: from_eid, connection_resource_id: from_device_id},
    to: %{eid: to_eid, connection_resource_id: to_device_id},
    signal_type: signal_type
    } = payload, state) do

    receiver = "#{from_eid}_#{to_eid}"  # message receiver
    sender = "#{to_eid}_#{from_eid}"  # message sender

    ack_message_receiver_state({receiver, signal_offset})
    move_receiver_offset_forward({receiver, signal_offset, from_device_id})
    ack_message_sender_state({sender, user_offset})
    fetch_reciever_ack = fetch_sender_ack(receiver, signal_offset)
    fetch_sender_ack = fetch_sender_ack(sender, user_offset)
    
    
    {:noreply, state}
  end

  def ack_message_receiver_state({user, offset}) do
    # ack message
    BimipLog.ack_status(user, "", 1, offset, :delivered)
  end

  def ack_message_sender_state({user, offset}) do
    # ack message
    BimipLog.ack_status(user, "", 1, offset, :delivered)
  end

  def move_receiver_offset_forward({user, offset, device_id}) do
    # Move offset forwars
    BimipLog.ack_message(user, device_id, 1, offset)
  end

  def fetch_receiver_ack({user, offset}) do
    # fetch the ack from the queue
    BimipLog.message_status(user, "", 1, offset)
  end

  def fetch_sender_ack({user, offset}) do
    # fetch the ack from the queue
    BimipLog.message_status(user, "", 1, offset)
  end

  def get_ack(user, offset) do
    # fetch the ack from the queue
    BimipLog.message_status(user, "", 1, offset)
  end


  def receiver_acknowledge_delivered() do

  end

  def sender_acknowledge_delivered() do

  end

end


# // -------------------------------------------------------------
# // status defines the real-time user activity or system state
# // -------------------------------------------------------------
# // 1 = CHATING        → User is actively chatting
# // 2 = RECORDING      → User is recording audio/video
# // 3 = PLAYED/VIEWED  → Media or message has been viewed/played
# // 4 = TYPING         → User is typing
# // 5 = PAUSED         → Typing/recording paused
# // 6 = CANCELLED      → Action cancelled
# // 7 = RESUME         → Action resumed
# // 8 = NOTIFICATION   → System/app notification (non-chat event)
# // -------------------------------------------------------------
# // ---------------- Signal ----------------
# // Used by both client and server to reconcile message status.
# // Supports dual reference (id + signal_id) for precise synchronization.
# message Signal {
#   string id = 1;            // client/queue message ID
#   int32 signal_offset = 2; // server-assigned global ID (monotonic or unique)
#   int32 user_offset = 3;   // server-assigned global ID (monotonic or unique)
#   int32 status = 4;     
#   int64 timestamp = 5;      // epoch ms
#   Identity from = 6;        // who sent the ACK
#   Identity to = 7;          // who receives the ACK
#   int32 type = 8;           // 1=REQUEST, 2=RESPONSE, 3=ERROR
#   int32 signal_type = 9;    // 1=SENDER  2=DEVICE  3=RECEIVER //check validator to see if not 
#   optional string error = 10;// optional error message if type=3
#   # bool signal_offset_state = 11 ;   // use to forward offset.
#   SignalAckState signal_ack_state = 12;  
# }

# message SignalAckState {
#   bool send = 1;
#   bool received = 2;
#   bool read = 3;
# }
