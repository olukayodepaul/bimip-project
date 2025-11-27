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
  @signal_request 2
  @stale_threshold_seconds ServerState.stale_threshold_seconds()

  # ----------------------
  # Public API
  # ----------------------
  def store_message(%Chat.MessageStruct{
        id: id,
        from: %Chat.EntityStruct{eid: from_eid},
        to: %Chat.EntityStruct{eid: to_eid},
        device_id: device_id
      } = payload) do
    from = Map.from_struct(payload.from)
    to = Map.from_struct(payload.to)

    queue_id = "#{from_eid}"
    reverse_queue_id = "#{to_eid}"

    # exactly once
    case get_message_offset(queue_id,  @partition_id, "id") do
      {:ok, ft_offset} ->
        send_signal_to_sender(id, ft_offset, @status, from, to, queue_id, device_id, @partition_id)
      {:error, :not_found} ->
        handle_new_message(id, payload,  queue_id, reverse_queue_id, from, to, device_id)
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

defp handle_new_message(id, payload, queue_id, reverse_queue_id, from, to, from_device_id) do
    with {:ok, offset} <- store_and_ack(id, payload, queue_id, from, to, from_device_id),
         {:ok, recv_offset} <- store_and_ack(id, payload, reverse_queue_id, from, to, from_device_id, receiver: true),
         {:ok, true} <- insert_message_id(queue_id, @partition_id, id, offset),
         {:ok, true} <- insert_message_id(reverse_queue_id, @partition_id, id, recv_offset) do
      # ... success code ...
    else
      # 1. Failure during store_and_ack for A_queue (must be defined by the helper)
      {:error, :a_queue_failed} = err ->
        Logger.error("TBOX_ERROR: [1/4] Queue A Store failed: #{inspect(err)}")
        {:error, :tbox_a_store_failed}

      # 2. Failure during store_and_ack for B_queue
      {:error, :b_queue_failed} = err ->
        Logger.error("TBOX_ERROR: [2/4] Queue B Store failed (A committed): #{inspect(err)}")
        {:error, :tbox_b_store_failed}

      # 3. *** NEW MATCH FOR A_QUEUE INDEX FAILURE (The :exists Error) ***
      {:error, :exists} = err -> # Note: This assumes 'offset' is bound *before* the failing step
        Logger.error("TBOX_ERROR: [3/4] Index A insertion failed (Key already exists): #{inspect(err)}. Possible producer retry.")
        {:error, :tbox_a_index_exists}

      # 4. *** NEW MATCH FOR B_QUEUE INDEX FAILURE (The :exists Error) ***
      #    This would only be hit if the previous step failed with a DIFFERENT error.
      {:error, :exists} = err ->
        Logger.error("TBOX_ERROR: [4/4] Index B insertion failed (Key already exists): #{inspect(err)}. Possible producer retry.")
        {:error, :tbox_b_index_exists}

      # CATCH-ALL: For any other unhandled {:error, reason}
      {:error, reason} ->
        Logger.error("TBOX_ERROR: [UNK] Unhandled error during TBox commit phase: #{inspect(reason)}")
        {:error, :tbox_unknown_commit_error}
    end
  end

  defp store_and_ack(id, payload, queue_id, from, to, from_device_id, opts \\ []) do
    is_receiver = Keyword.get(opts, :receiver, false)

    with {:ok, offset} <- Injection.store_message(queue_id, @partition_id, from, to, payload, id),
        {:ok, _} <- maybe_advance_offset(queue_id, from_device_id, @partition_id, offset, is_receiver),
        {:atomic, _} <- Injection.mark_ack_status(queue_id, from_device_id, @partition_id, offset, :sent) do
      {:ok, offset}
    end
  end

  defp maybe_advance_offset(_queue, _device, _partition, offset, true), do: {:ok, offset}
  defp maybe_advance_offset(queue, device, partition, offset, false),
    do: Injection.advance_offset(queue, device, partition, offset)

  defp push_to_device(payload, signal_offset, user_offset, signal_type, queue_id, device_id, opts \\ []) do
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

  defp insert_message_id(user,  partition, message_id, offset),
    do: Injection.insert_message_id(user, partition, message_id, offset)

  defp get_ack_status(user, device, partition, offset),
    do: Injection.get_ack_status(user, device, partition, offset)

  defp confirm_advance_offset(user, device, partition, offset),
    do: Injection.confirm_advance_offset(user, device, partition, offset)

  defp set_message_fields(payload, signal_offset, user_offset, signal_type) do
    Map.merge(payload, %{
      signal_type: signal_type,
      user_offset: user_offset,
      signal_offset: signal_offset,
      signal_request: @signal_request,
      owner: payload.from
    })
  end

  defp send_signal_to_sender(id, offset, status, from, to, user, from_device_id, partition_id) do

    %{
      id: id,
      signal_offset: offset,
      user_offset: offset,
      status: status,
      from: to,
      to: from,
      signal_type: 1,
      signal_request: 2,
      signal_ack_state: %{send: true, delivered: false, read: false, advance_offset: true}
    }
    |> ThrowSignalSchema.success()
    |> then(&Connect.outbouce(from_device_id, &1))
  end

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
