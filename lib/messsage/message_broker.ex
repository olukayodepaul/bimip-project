defmodule Message.Broker do

  alias Route.Connect
  @num_shards 64

  def send_message(
    %{
      message: %Bimip.Message{from: from_eid, to: to_eid} = message,
      device_id: device_id,
      uupid: uupid
    } = message_builder
  ) do

    shard = :erlang.phash2(message.from.eid, @num_shards)
    suffix = :crypto.strong_rand_bytes(8) |> Base.encode16()

    message_id = if message.message_type == 2 do
      "#{message.content_type}-#{message.id}-#{suffix}"
    else
      "#{message.content_type}-#{message.id}"
    end

    case Queue.MessageTracker.check_and_insert(shard, message.from.eid, device_id, message_id, message_builder) do
      {:ok, :inserted, offset} ->
        IO.inspect({:ok, :inserted, offset})
      {:error, :already_exists, offset} ->
        ThrowMessageDeliveryReceiptsSchema.build(message.id, to_eid, from_eid, offset, Until.UniPosTime.response_time())
        |> then(&Connect.outbouce(device_id, &1))
    end

  end

end
