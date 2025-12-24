defmodule Chat.SendMessage do
  @moduledoc """
  Handles message storage, acknowledgment, and delivery to sender/receiver devices.
  """
  require Logger

  alias Queue.Injection
  alias Route.Connect
  alias Settings.ServerState
  alias Storage.DeviceStorage

  @partition_id 1
  @transmission_mode 2
  @stale_threshold_seconds ServerState.stale_threshold_seconds()
  @types 2
  @nil_device 0

  # ----------------------
  # Public API
  # ----------------------
  def store_message(%Chat.MessageStruct{peer_uid: id, from: from_struct, to: to_struct} = payload) do
    # Convert structs to maps once at the entry point
    from = Map.from_struct(from_struct)
    to = Map.from_struct(to_struct)

    IO.inspect({from, to})

    case get_message_offset(from.eid, @partition_id, id) do
      {:ok, offset} ->
        IO.inspect(1)
        send_signal_to_sender(id, offset, from, to)

      {:error, :not_found} ->
        IO.inspect(2)
        handle_new_message(id, payload, from.eid, to.eid, from, to)
    end
  end

  defp handle_new_message(id, payload, q_id, rev_q_id, from, to) do
    with {:ok, offset} <- store_and_ack(id, payload, q_id, from, to),
        {:ok, recv_offset} <- store_and_ack(id, payload, rev_q_id, from, to, offset),
        {:ok, _} <- insert_message_id(q_id, rev_q_id, @partition_id, id, offset, recv_offset) do

      send_signal_to_sender(id, offset, from, to)

      # Deliveries
      push_message(payload, offset, offset, from.eid, payload.device_id, :device)
      push_message(payload, offset, recv_offset, from.eid, payload.device_id, :recipient)
      :ok
    else
      {:error, reason} ->
        Logger.error("Message processing failed for #{id}: #{inspect(reason)}")
        :ok
    end
  end

  # Helper to clean up Injection calls
  defp store_and_ack(id, payload, q_id, from, to, snd_offset \\ nil),
    do: Injection.store_message(q_id, @partition_id, from, to, payload, id, snd_offset)

  defp push_message(payload, offset, recv_offset, eid, device_id, target) do

    peer_offset = if target == :device, do: offset, else: recv_offset

    payload
    |> set_message_fields(offset, peer_offset)
    |> deliver_to_online_devices(eid, device_id, target)
  end

  defp get_message_offset(u, p, id), do: Injection.get_message_offset(u, p, id)

  defp insert_message_id(q, rq, p, id, o, ro), do: Injection.insert_message_id(q, rq, p, id, o, ro)

  defp set_message_fields(message, msg_offset, peer_offset) do
    %{
      peer_uid: message.peer_uid,
      from: Map.from_struct(message.from),
      to: Map.from_struct(message.to),
      timestamp: Until.UniPosTime.uni_pos_time(),
      payload: message.payload,
      encryption_type: message.encryption_type,
      encrypted: message.encrypted,
      signature: message.signature,
      type: @types,
      transmission_mode: @transmission_mode,
      peer_eid: message.to.eid,
      offset: msg_offset
    }
  end

  defp send_signal_to_sender(id, offset, from, to) do
    %{
      offset: offset,
      from: %Bimip.Identity{eid: to.eid},
      to: %Bimip.Identity{eid: from.eid},
      peer_uid: id,
      peer_eid:  to.eid # Anchor Model: use sender offset
    }
    |> ThrowMessagePeerAckSignalSchema.build()
    |> then(&Connect.outbouce(from.connection_resource_id, &1))
  end

  defp deliver_to_online_devices(payload, eid, device_id, target) do
    now = DateTime.utc_now()

    case target do
      :device ->
        DeviceStorage.fetch_devices_by_eid(eid)
        |> Stream.filter(&(&1.status == "ONLINE" and DateTime.diff(now, &1.last_seen) <= @stale_threshold_seconds and &1.device_id != device_id))
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
        %{eid: peer_eid} = payload.from

        %{payload |
          type: 3,
          peer_eid: peer_eid
        }
        |> then(&Connect.handle_inbouce_signal({:eid, &1.to.eid, :send_message_to_receiver_server, &1}))
    end
  end

  def process_receiver_message(payload, eid), do: deliver_to_online_devices(payload, eid, @nil_device, :device)
end
