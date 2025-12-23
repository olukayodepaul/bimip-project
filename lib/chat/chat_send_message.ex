defmodule Chat.SendMessage do
  @moduledoc """
  Handles message storage, acknowledgment, and delivery to sender/receiver devices.

  Responsibilities:
  - Store incoming messages in per-user queues
  - Acknowledge message offsets
  - Send signals back to sender
  - Deliver messages to sender's other devices and receiver devices
  """

  require Logger

  alias Queue.Injection
  alias Route.Connect
  alias Settings.ServerState
  alias Storage.DeviceStorage

  @partition_id 1
  @sender_signal_type 2
  @receiver_signal_type 3
  @status 1
  @transmission_mode 2
  @stale_threshold_seconds ServerState.stale_threshold_seconds()
  @types 2
  @nil_device 0

  # ----------------------
  # Public API
  # ----------------------
  def store_message(%Chat.MessageStruct{
        message_id: message_id,
        from: %Chat.EntityStruct{eid: from_eid},
        to: %Chat.EntityStruct{eid: to_eid},
        device_id: device_id,
      } = payload) do

    from = Map.from_struct(payload.from)
    to = Map.from_struct(payload.to)

    queue_id = "#{from_eid}"
    reverse_queue_id = "#{to_eid}"

    case get_message_offset(queue_id,  @partition_id, message_id) do
      {:ok, offset} ->
        send_signal_to_sender(message_id, offset, from, to)
        handle_new_message(message_id, payload,  queue_id, reverse_queue_id, from, to, from_eid, device_id)
      {:error, :not_found} ->
        handle_new_message(message_id, payload,  queue_id, reverse_queue_id, from, to, from_eid, device_id)
    end
  end


  defp handle_new_message(id, payload, queue_id, reverse_queue_id, from, to, eid, device_id) do

    case store_message_and_ack(id, payload, queue_id, from, to) do
      {:ok, offset} ->
        case store_message_and_ack(id, payload, reverse_queue_id, from, to, offset) do
          {:ok, recv_offset} ->
            case insert_message_id(queue_id, reverse_queue_id, @partition_id, id, offset, recv_offset) do
              {:ok, _offsets} ->

                  send_signal_to_sender(id, offset,  from, to)
                  push_message(payload, offset, offset, eid, device_id, :device)
                  push_message(payload, offset, recv_offset, eid, device_id, :recipient)
                  :ok
              {:error, reason} ->

                IO.inspect({reason})
              _recovery_data = [
                  %{
                    message_id: id,
                    queue: queue_id,
                    offset: offset,
                    retries: 0,
                    inserted_at: Until.UniPosTime.uni_pos_time()
                  },
                  %{
                    message_id: id,
                    queue: reverse_queue_id,
                    offset: recv_offset,
                    retries: 0,
                    inserted_at: Until.UniPosTime.uni_pos_time()
                  },
                ]
                # Queue.Recovery.enqueue_id_link_failure(recovery_data)
                :ok
            end

          {:error, _reason} ->
            # Queue.Recovery.enqueue_id_link_failure(recovery_data)
            :ok
        end

      {:error, _reason} -> :ok
    end
  end

  defp store_message_and_ack(id, payload, queue_id, from, to, sender_offset \\ nil) do
    # is_receiver = Keyword.get(opts, :receiver, false)
    with {:ok, offset} <- Injection.store_message(queue_id, @partition_id, from, to, payload, id, sender_offset) do
        # {:atomic, _} <- Injection.mark_ack_status(queue_id, from_device_id, @partition_id, offset, :sent) do
      {:ok, offset}
    end
  end

  defp push_message(payload, offset, recv_offset, eid, device_id, recipient_or_device) do

    {msg_offset, peer_offset} = if recipient_or_device == :device do {offset, offset} else {offset, recv_offset} end

    payload
    |> set_message_fields(msg_offset, peer_offset)
    |> deliver_to_online_devices(eid, device_id, recipient_or_device)
  end

  defp get_message_offset(user, partition, message_id),
    do: Injection.get_message_offset(user, partition, message_id)

  defp insert_message_id(queue_id, reverse_queue_id, @partition_id, id, offset, recv_offset),
    do: Injection.insert_message_id(queue_id, reverse_queue_id, @partition_id, id, offset, recv_offset)

  defp set_message_fields(%Chat.MessageStruct{} = message, msg_offset, peer_offset) do

    %Chat.EntityStruct{
      eid: from_eid,
      connection_resource_id: from_device_id
    } = message.from

    %Chat.EntityStruct{
      eid: to_eid,
      connection_resource_id: to_device_id
    } = message.to

    %{
      message_id: message.message_id,
      from: %{eid: from_eid, connection_resource_id: from_device_id},
      to: %{eid: to_eid, connection_resource_id: to_device_id},
      timestamp:  Until.UniPosTime.uni_pos_time(),
      payload: message.payload,
      encryption_type: message.encryption_type,
      encrypted: message.encrypted,
      signature: message.signature,
      type: @types,
      transmission_mode: @transmission_mode,
      peer: %{to: to_eid, peer_offset: peer_offset},
      offset: msg_offset
      }

  end

  defp send_signal_to_sender(message_id, offset,  from, to) do
    %{
      offset: offset,
      from: %Bimip.Identity{eid: to.eid},
      to: %Bimip.Identity{eid: from.eid},
      message_id: message_id,
      peer: %Bimip.Peer{ to: to.eid,  peer_offset: offset}
    }
    |> ThrowMessagePeerAckSignalSchema.build()
    |> then(&Connect.outbouce(from.connection_resource_id, &1))
  end


  defp deliver_to_online_devices( %{} = payload,  eid, device_id, recipient_or_devce ) do

    now = DateTime.utc_now()

    case recipient_or_devce do

      :device ->
        # Change to genserver state

        DeviceStorage.fetch_devices_by_eid(eid)

        |> Stream.filter(fn device ->
        device.status == "ONLINE" and DateTime.diff(now, device.last_seen) <= @stale_threshold_seconds and device.device_id != device_id
        end)
        |> Task.async_stream(
        fn device ->
          payload
          |> set_from(device.eid, device.device_id)
          |> ThrowMessageSchema.build_message()
          |> then(&Connect.outbouce(device.device_id, &1))
        end,
        max_concurrency: 10,
        timeout: 5_000,
        on_timeout: :kill_task
        )
        |> Stream.run()

      :recipient ->

        %{eid: peer_eid} = payload.from

        %{payload |
          type: 3,
          peer: %{
            payload.peer |
            to: peer_eid
          }
        }
        |> server_route(:send_message_to_receiver_server)

    end
  end

  def process_receiver_message(%{} = payload, eid) do
    deliver_to_online_devices(payload,  eid, @nil_device, :device)
  end

  defp set_from(payload, eid, device_id), do: %{payload | to: %{eid: eid, connection_resource_id: device_id}}
  defp server_route(payload,  server), do: { :eid, payload.to.eid, server, payload } |> Connect.handle_inbouce_signal()
end
