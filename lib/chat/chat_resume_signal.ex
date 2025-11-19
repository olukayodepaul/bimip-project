defmodule Chat.ResumeSignal do
  alias Queue.Injection
  alias Until.UniPosTime
  alias ThrowMessageSchema

  @partition_id 1

  def resume(%Chat.ResumeStruct{
        from: %{eid: from_eid, connection_resource_id: device_id},
        to: %{eid: to_eid},
      } = _payload) do

    queue_id = "#{from_eid}_#{to_eid}"

    case Injection.fetch_messages(queue_id, device_id, @partition_id) do
      {:ok, %{messages: [message]}} ->

        msg =
          message
          |> set_message_fields()
          |> Map.put(:signal_offset_state, false)
          |> Map.put(:timestamp, UniPosTime.uni_pos_time())
          |> ThrowMessageSchema.build_message()

        IO.inspect(msg)

      {:error, reason} ->
        IO.puts("Failed to fetch messages: #{inspect(reason)}")
        nil
    end
  end

  defp set_message_fields(%{
        payload: %{
          id: id,
          from: from,
          to: to,
          payload: payload,
          encryption_type: encryption_type,
          encrypted: encrypted,
          signature: signature,
          user_offset: user_offset,
          signal_offset: signal_offset,
          eid: eid
        }
      }) do

    signal_type = if eid == from.eid, do: 2, else: 3
    queue_id = "#{from.eid}_#{to.eid}"

    %{
      id: id,
      from: from,
      to: to,
      payload: payload,
      encryption_type: encryption_type,
      encrypted: encrypted,
      signature: signature,
      user_offset: String.to_integer(user_offset),
      signal_offset: String.to_integer(signal_offset),
      signal_type: signal_type,
      signal_ack_state:
        Injection.get_ack_status(
          queue_id,
          "",
          @partition_id,
          String.to_integer(signal_offset)
        )
    }
  end
end
