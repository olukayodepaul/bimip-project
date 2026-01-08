defmodule Chat.SendMessage do

  alias Route.Connect

  @stale_threshold_seconds Settings.ServerState.stale_threshold_seconds()
  @types 2
  @transmission_mode 2

  def send_received_ack_to_sender(id, from, to, offset, app_device_id) do
    %{
      offset: offset,
      from: %Bimip.Identity{eid: to},
      to: %Bimip.Identity{eid: from},
      peer_uid: id,
      reply_to:  to
    }
    |> ThrowMessagePeerAckSignalSchema.build()
    |> then(&Connect.outbouce(app_device_id, &1))
  end

  def push_message_to_other_devices(%Chat.MessageStruct{} = payload, offset, recipient, devices) do
    set_message_fields(payload,offset,recipient, devices)
  end

  def set_message_fields(%Chat.MessageStruct{} = payload, offset, recipient, devices) do

    %Chat.EntityStruct{eid: from_eid, connection_resource_id: from_device} = payload.from
    %Chat.EntityStruct{eid: to_eid} = payload.to

    message = %{
      peer_uid: payload.peer_uid,
      offset: offset,
      timestamp: Until.UniPosTime.uni_pos_time(),
      type: @types,
      signature: payload.signature,
      from: %{eid: from_eid, connection_resource_id: from_device},
      to: %{eid: to_eid, connection_resource_id: nil},
      payload: payload.payload,
      payload_context: payload.payload_context,
      encryption_type: payload.encryption_type,
      encrypted: payload.encrypted,
      transmission_mode: @transmission_mode,
      reply_to: to_eid
    }

    Task.Supervisor.start_child(Chat.TaskSupervisor, fn ->
      push_to_devices(message, from_eid, from_device,  devices)
    end)

    if recipient == :device do
      Task.Supervisor.start_child(Chat.TaskSupervisor, fn ->
       message
        |> Map.put(:uupid, payload.uupid)
        |> transmit_to_rcv(to_eid)
      end)
    end

  end

  defp push_to_devices(payload, from_eid, from_device,  devices) do
    now = DateTime.utc_now()

    online_devices =
      devices
      |> Enum.filter(fn {_device_id, dev} ->
        DateTime.diff(now, dev.last_seen, :second) <= @stale_threshold_seconds and
          dev.device_id != from_device
      end)
      |> Enum.map(fn {_device_id, dev} -> dev end)

    online_devices
    |> Task.async_stream(
      fn dev ->
        payload
        |> then(&%{&1 | to: %{eid: dev.eid, connection_resource_id: dev.device_id}})
        |> ThrowMessageSchema.build_message()
        |> then(&Connect.outbouce(dev.device_id, &1))
      end,
      max_concurrency: 10,
      ordered: false,
      timeout: 5_000
    )
    |> Stream.run()
  end


  defp transmit_to_rcv(payload, to_eid) do
    payload
    |> then(&Connect.handle_inbouce_signal({:eid, to_eid, :message_transmiter, &1}))
  end

  def map_to_message_struct(payload) do
    %{
        peer_uid: payload.peer_uid,
        timestamp: Until.UniPosTime.uni_pos_time(),
        payload: payload.payload,
        payload_context: payload.payload_context,
        encryption_type: payload.encryption_type,
        encrypted: payload.encrypted,
        signature: payload.signature,
        device_id: payload.from.connection_resource_id,
        uupid: payload.uupid,
        eid: payload.from.eid,
        from: %Chat.EntityStruct{
          eid: payload.from.eid,
          connection_resource_id: payload.from.connection_resource_id
        },
        to: %Chat.EntityStruct{eid: payload.to.eid, connection_resource_id: nil}
      }
      |> Chat.Message.Model.to_message_struct()
      |> IO.inspect()
  end

end
