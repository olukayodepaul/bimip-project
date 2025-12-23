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
  @signal_direction 2
  @stale_threshold_seconds ServerState.stale_threshold_seconds()

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
      {:error, :not_found} ->
        handle_new_message(message_id, payload,  queue_id, reverse_queue_id, from, to)
    end

  end

  def process_receiver_message(%Chat.MessageStruct{to: %Chat.EntityStruct{eid: eid}} = payload) do
    deliver_to_online_devices(eid, payload)
    :ok
  end

  def send_message_to_sender_other_devices(%Chat.MessageStruct{
        from: %Chat.EntityStruct{eid: eid},
        device_id: device_id
      } = payload) do
    deliver_to_online_devices(eid, payload, exclude_device: device_id)
    :ok
  end

  defp handle_new_message(id, payload, queue_id, reverse_queue_id, from, to) do

    case store_message_and_ack(id, payload, queue_id, from, to) do
      {:ok, offset} ->
        case store_message_and_ack(id, payload, reverse_queue_id, from, to, offset) do
          {:ok, recv_offset} ->
            case insert_message_id(queue_id, reverse_queue_id, @partition_id, id, offset, recv_offset) do
              {:ok, offsets} ->
                IO.inspect({"offsets"})
                # send message to device and sender
                  # send_signal_to_sender(id, offset, @status, from, to, queue_id, from_device_id, @partition_id)
                  # push_to_device(payload, offset, offset, @sender_signal_type)
                  # push_to_device(payload, recv_offset, offset, @receiver_signal_type, receiver: true)
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

  defp push_to_device(payload, signal_offset, user_offset, signal_type,  opts \\ []) do
    is_receiver = Keyword.get(opts, :receiver, false)

    payload
    |> set_message_fields(signal_offset, user_offset, signal_type)
    |> send_to_device(is_receiver)
  end

  defp send_to_device(payload, false), do: send_message_to_sender_other_devices(payload)
  defp send_to_device(payload, true), do: server_route(payload, :eid, :send_message_to_receiver_server)

  # ----------------------
  # Helpers
  # ----------------------
  defp get_message_offset(user, partition, message_id),
    do: Injection.get_message_offset(user, partition, message_id)

  defp insert_message_id(queue_id, reverse_queue_id, @partition_id, id, offset, recv_offset),
    do: Injection.insert_message_id(queue_id, reverse_queue_id, @partition_id, id, offset, recv_offset)


  defp set_message_fields(payload, signal_offset, user_offset, signal_type) do
    Map.merge(payload, %{
      signal_type: signal_type,
      user_offset: user_offset,
      signal_offset: signal_offset,
      signal_direction: @signal_direction,
      owner: %{from: payload.from.eid, to: payload.to.eid}
    })
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


    # 📌 Arch Strategy: State-in-Process & Atomic RPC
    #   Process-as-Storage: Move device metadata from DeviceStorage (DB) into the Mother GenServer State. Eliminates DB bottlenecks during message fan-out.
    #   Atomic Serialization: Use GenServer.call for device updates. The Mother’s mailbox acts as a natural mutex, preventing race conditions between multiple devices.
    #   Direct Addressing: Use [PID, Node] metadata in messages. Replace global registries (Horde) with Local Registry + RPC to reduce cluster-wide sync noise.
    #   Process Monitoring: Mother calls Process.monitor/1 on all Client PIDs.
    #   Effect: Instant cleanup of "Online" status via :DOWN messages instead of polling a "Last Seen" timestamp.
    #   Hybrid Geo-Routing: Keep the "Mother" anchored in the home region (Nigeria) for data consistency, but terminate the "Client" at the Edge (London) for low-latency handshakes.
    #   Also comit state should be move to genserver state

    defp deliver_to_online_devices(eid, payload, opts \\ []) do
    exclude_device = Keyword.get(opts, :exclude_device, nil)
    now = DateTime.utc_now()

    DeviceStorage.fetch_devices_by_eid(eid)
    |> Stream.filter(fn device ->
      device.status == "ONLINE" and DateTime.diff(now, device.last_seen) <= @stale_threshold_seconds and
        (is_nil(exclude_device) or device.device_id != exclude_device)
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
  end

  defp set_from(payload, eid, device_id), do: %{payload | to: %{eid: eid, connection_resource_id: device_id}}
  defp server_route(payload, _eid, server), do: { :eid, payload.to.eid, server, payload } |> Connect.handle_inbouce_signal()
end
