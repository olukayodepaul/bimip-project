defmodule Message.Broker do
  alias Route.Connect
  @num_shards 64

  # ----------------------------------------------------------------------------
  # Sender Logic
  # ----------------------------------------------------------------------------

  def sender(
        %{
          message: %Bimip.Message{from: from_eid, to: to_eid} = message,
          device_id: device_id,
          uupid: uupid
        } = _message_builder,
        all_devices
      ) do
    shard = :erlang.phash2(message.from.eid, @num_shards)
    suffix = :crypto.strong_rand_bytes(8) |> Base.encode16()

    message_id =
      if message.message_type in [2, 6, 7] do
        "#{message.id}-#{suffix}"
      else
        "#{message.id}"
      end

    result =
      message
      |> Map.put(:participant_role, 2)

    case Queue.MessageTracker.check_and_insert(shard, message.from.eid, device_id, message_id, %{
           message_builder: result,
           delim: :sender,
           uuid: uupid,
           ts: System.system_time(:millisecond)
         }) do
      {:ok, :inserted, sender_offset} ->
        result
        |> Map.put(:offset, sender_offset)
        |> ThrowMessageSchema.build_message()
        |> then(&Device.Transmission.emit(message.from.eid, device_id, all_devices, &1))

        message_receipt(message.id, to_eid, from_eid, sender_offset, device_id)

      {:error, :already_exists, sender_offset} ->
        message_receipt(message.id, to_eid, from_eid, sender_offset, device_id)
    end
  end

  # ----------------------------------------------------------------------------
  # Receiver Logic
  # ----------------------------------------------------------------------------

  def recv(
        %{
          message:
            %Bimip.Message{from: _from_eid, to: _to_eid, delivery_type: delv_type} = message,
          device_id: device_id,
          uupid: uupid
        } = _message_builder, roster
      ) do

    shard = :erlang.phash2(message.to.eid, @num_shards)
    suffix = :crypto.strong_rand_bytes(8) |> Base.encode16()

    message_id =
      if message.message_type in [2, 6, 7] do
        "#{message.id}-#{suffix}"
      else
        "#{message.id}"
      end

    result =
      message
      |> Map.put(:participant_role, 3)

    case Queue.MessageTracker.check_and_insert(shard, message.to.eid, device_id, message_id, %{
           message_builder: result,
           delim: :recv,
           uuid: uupid,
           device_id: 0,
           ts: System.system_time(:millisecond)
         }) do
      {:ok, :inserted, receiver_offset} ->
        if delv_type == 1 do
          result
          |> Map.put(:offset, receiver_offset)
          |> ThrowMessageSchema.build_message()
          |> then(&Connect.client_server_inbound({:eid, message.to.eid, :message_transmiter, &1}, roster))
        end

      {:error, :already_exists, _offset} ->
        :ok
    end
  end

  # ----------------------------------------------------------------------------
  # Receipt Helper
  # ----------------------------------------------------------------------------

  def message_receipt(
        message_id,
        to_eid,
        %Bimip.Identity{eid: eid} = from_eid,
        sender_offset,
        device_id
      ) do
    ThrowMessageDeliveryReceiptsSchema.build(
      message_id,
      to_eid,
      from_eid,
      sender_offset,
      Until.UniPosTime.response_time()
    )
    |> then(&Device.Transmission.emit_single(device_id, eid, &1))
  end
end
