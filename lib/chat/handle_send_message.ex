defmodule ChatMessage.SentMessage do

  alias Route.AwarenessFanOut
  alias BimipLog
  alias App.RegistryHub

  def incomig_message({from, to, id, payload}, state) do

    partition_id = 1
    signal_type = 2
    
    %{eid: from_eid, connection_resource_id: from_device_id} = from
    %{eid: to_eid, connection_resource_id: to_device_id} = to
    
    # ----------------------
    # Queue keys (directional)
    # ----------------------
    user_a = "#{from_eid}_#{to_eid}"  # sender queue
    user_b = "#{to_eid}_#{from_eid}"  # recipient queue
    user_c = "#{from_eid}_#{to_eid}"

    sender_payload = Map.merge(payload, %{
      signal_type: 1,
      device_id: from_device_id
    })

    case BimipLog.write(user_a, partition_id, from, to, sender_payload) do
      {:ok, signal_offset_a} ->

        BimipLog.ack_message(user_a, from_device_id, 1, signal_offset_a)
        BimipLog.ack_status(user_a, "", 1, signal_offset_a, :sent)

        receiver_payload = Map.merge(payload, %{
          signal_type: 3,
          device_id:  from_device_id
        })

        case BimipLog.write(user_b, partition_id, from, to, receiver_payload, signal_offset_a) do
          {:ok, signal_offset_b} ->

            pair_fan_out = ThrowSignalSchema.success(
                from_eid, 
                from_device_id,
                to_eid,
                to_device_id,
                1,
                signal_offset_a,
                signal_offset_a,
                id,
                ""
              )
            BimipLog.ack_status(user_b, "", 1, signal_offset_b, :sent)
            AwarenessFanOut.pair_fan_out({pair_fan_out, from_device_id, from_eid})

            AwarenessFanOut.send_direct_message(
              BimipLog.message_status(user_a, "", 1, signal_offset_a),
              from_eid, signal_offset_a, signal_offset_a, sender_payload, from_device_id, signal_type
            )

            transport =  Map.merge(receiver_payload, %{
              signal_offset: signal_offset_b,
              user_offset: signal_offset_a,
              signal_offset_state: false,
              signal_ack_state: BimipLog.message_status(user_b, "", 1, signal_offset_b)
            })

            RegistryHub.send_chat(transport)
            
          {:error, reason} ->
            IO.inspect(reason, label: "[WRITE ERROR B ← A]")
        end

      {:error, reason} ->
        IO.inspect(reason, label: "[WRITE ERROR A → B]")
    end

    {:noreply, state}
  end

end