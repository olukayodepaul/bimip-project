defmodule Chat.SendMessage do

  alias Route.Connect
  alias Storage.DeviceStorage


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

   def push_message_to_other_devices(%Chat.MessageStruct{} = payload, offset, recipient) do
      set_message_fields(
        payload,
        offset,
        recipient
      )
  end

  def set_message_fields(%Chat.MessageStruct{} = payload, offset, td) do

    %Chat.EntityStruct{eid: from_eid, connection_resource_id: from_device} = payload.from
    %Chat.EntityStruct{eid: to_eid, connection_resource_id: to_device} = payload.to

    message = %{
      peer_uid: payload.peer_uid,
      offset: offset,
      timestamp: Until.UniPosTime.uni_pos_time(),
      type: @types,
      signature: payload.signature,
      to: %{eid: to_eid, connection_resource_id: to_device},
      from: %{eid: from_eid, connection_resource_id: from_device},
      payload: payload.payload,
      payload_context: payload.payload_context,
      encryption_type: payload.encryption_type,
      encrypted: payload.encrypted,
      transmission_mode: @transmission_mode,
      reply_to: to_eid
    }

    Task.Supervisor.start_child(Chat.TaskSupervisor, fn ->
      push_to_devices(message, from_eid, from_device, td)
    end)

    if td == :device do
      Task.Supervisor.start_child(Chat.TaskSupervisor, fn ->
        transmit_to_rcv(message, to_eid)
      end)
    end

  end

  defp push_to_devices(payload, from_eid, from_device, td) do
    now = DateTime.utc_now()

    case td do
      :device ->

        DeviceStorage.fetch_devices_by_eid(from_eid)
        |> Stream.filter(&(&1.status == "ONLINE" and DateTime.diff(now, &1.last_seen) <= @stale_threshold_seconds and &1.device_id != from_device))
        |> Task.async_stream(fn dev ->
          payload
          |> then(&(%{ &1 | to: %{eid: dev.eid, connection_resource_id: dev.device_id}}))
          |> ThrowMessageSchema.build_message()
          |> then(&Connect.outbouce(dev.device_id, &1))
        end,
        max_concurrency: 10,
        ordered: false,
        timeout: 5_000
        )
        |> Stream.run()

      :recipient ->
       :ok # change this to recipient
    end
  end

  defp transmit_to_rcv(payload, to_eid) do
    payload
    |> then(&Connect.handle_inbouce_signal({:eid, to_eid, :message_transmiter, &1}))
  end

end











#       transmission_mode: transmission_mode,
#       reply_to: reply_to

#    message Message {
#     string peer_uid = 1;
#     Identity from = 2;
#     Identity to = 3;
#     int64 timestamp = 4;
#     bytes payload = 5;
#     string encryption_type = 6;
#     string encrypted = 7;
#     string signature = 8;
#     optional int32 type = 9;
#     optional int32 transmission_mode = 10;
#     optional string reply_to = 11;
#     optional int64 offset = 12;
#     int32 payload_context = 13;
#   }


#   %Chat.MessageStruct{
#   peer_uid: "vcNAQcDoIIB4TCCAd0CAQAxggE2MIIBMgI",
#   timestamp: 1767297509803,
#   payload: "\"This is the test message 👋\"",
#   payload_context: 1,
#   encryption_type: "E2E",
#   encrypted: "MIIB8AYJKoZIhvcNAQcDoIIB4TCCAd0CAQAxggE2MIIBMgIBADAfMA4GCSqGSIb3DQEBCwUwggExBgsqhkiG9w0BCwEw",
#   signature: "SHA256-R4f0S4E3V7gH6tK2mP9Yc0B1dZ2eG3h4iJ5kL7o9pQ8rT6uV5wX4yZ3aBcD1fG0hI7jKmNlOpZqRsT",
#   device_id: 5,
#   app_device_id: "aaaaa1",
#   eid: "a@domain.com",
#   from: %Chat.EntityStruct{eid: "a@domain.com", connection_resource_id: 5},
#   to: %Chat.EntityStruct{eid: "b@domain.com", connection_resource_id: nil}
# }
