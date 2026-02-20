defmodule Message.Broker do

  alias Route.Connect
  @num_shards 64

  def sender(
    %{
      message: %Bimip.Message{from: from_eid, to: to_eid} = message,
      device_id: device_id,
      uupid: uupid
    } = message_builder, all_devices
  ) do


    shard = :erlang.phash2(message.from.eid, @num_shards)
    suffix = :crypto.strong_rand_bytes(8) |> Base.encode16()

    message_id = if message.message_type == 2 do
      "#{message.content_type}-#{message.id}-#{suffix}"
    else
      "#{message.content_type}-#{message.id}"
    end

    case Queue.MessageTracker.check_and_insert(shard, message.from.eid, device_id, message_id, %{message_builder: message_builder, delim: :sender}) do
      {:ok, :inserted, sender_offset} ->

        message
        |> Map.put(:offset, sender_offset)
        |> Map.put(:participant_role, 2)
        |> Map.put(:delivery_type, 1)
        |> ThrowMessageSchema.build_message()
        |> then(&push_to_devices(message.from.eid, device_id, all_devices, &1))

        message_receipt(message.id, to_eid, from_eid, sender_offset, device_id)

      {:error, :already_exists, sender_offset} ->
        message_receipt(message.id, to_eid, from_eid, sender_offset, device_id)
    end
  end

  def recv(
    %{
      message: %Bimip.Message{from: from_eid, to: to_eid} = message,
      device_id: device_id,
      uupid: uupid
    } = message_builder
  ) do

    shard = :erlang.phash2(message.to.eid, @num_shards)
    suffix = :crypto.strong_rand_bytes(8) |> Base.encode16()

    message_id = if message.message_type == 2 do
      "#{message.content_type}-#{message.id}-#{suffix}"
    else
      "#{message.content_type}-#{message.id}"
    end

    case Queue.MessageTracker.check_and_insert(shard, message.to.eid, device_id, message_id, %{message_builder: message_builder, delim: :sender}) do
      {:ok, :inserted, receiver_offset} ->

         message
          |> Map.put(:offset, receiver_offset)
          |> Map.put(:participant_role, 3)
          |> Map.put(:delivery_type, 1)
          |> ThrowMessageSchema.build_message()
          |> then(&Connect.client_server_inbound({:eid, message.to.eid, :message_transmiter, &1}))

      {:error, :already_exists, offset} ->
       :ok
    end
  end

  def push_to_devices(eid, device_id,  all_devices, payload) do

    stale_limit = get_stale_threshold()
    now = DateTime.utc_now()

    online_devices =
      all_devices
      |> Enum.filter(fn {_id, dev} ->
        DateTime.diff(now, dev.last_seen, :second) <= stale_limit and
          dev.device_id != device_id
      end)
      |> Enum.map(fn {_id, dev} -> dev end)

      online_devices
      |> Task.async_stream(
        fn dev ->
          Connect.outbouce(dev.device_id, payload)
        end,
        max_concurrency: 10,
        ordered: false,
        timeout: 5_000
      )
      |> Stream.run()

  end

  defp subscribers_validation(eid) do

  end

  def message_receipt(message_id, to_eid, from_eid, sender_offset, device_id) do
    ThrowMessageDeliveryReceiptsSchema.build(message_id, to_eid, from_eid, sender_offset, Until.UniPosTime.response_time())
    |> then(&Connect.outbouce(device_id, &1))
  end

  defp get_stale_threshold do
    Settings.Connections.stale_threshold_seconds()
  end

end
