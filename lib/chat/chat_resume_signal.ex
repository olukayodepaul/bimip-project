defmodule Chat.ResumeSignal do
  alias Queue.Injection
  alias Until.UniPosTime
  alias ThrowMessageSchema
  alias Route.{SignalCommunication}

  @partition_id 1

  def resume(%Chat.ResumeStruct{
        from: %{eid: from_eid, connection_resource_id: device_id},
        to: %{eid: to_eid},
        eid: eid,
        device: device
      } = _payload) do

    queue_id = "#{from_eid}_#{to_eid}"

    case Injection.fetch_messages(queue_id, device_id, @partition_id) do
      {:ok, %{messages: [message]}} ->

        if message != %{} do
          message
          |> set_message_fields()
          |> set_signal_type(eid)
          |> Map.put(:signal_offset_state, false)
          |> Map.put(:timestamp, UniPosTime.uni_pos_time())
          |> ThrowMessageSchema.build_message()
          |> send_signal_to_sender(%{eid: from_eid, connection_resource_id: device_id})
        end

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
      signal_request: 1,
      signal_ack_state:
        Injection.get_ack_status(
          queue_id,
          "",
          @partition_id,
          String.to_integer(signal_offset)
        )
    }
  end

  def set_signal_type(payload, eid) do
    %{from: %{eid: message_eid}} = payload
    signal_type = if eid == message_eid, do: 2, else: 3
    payload
    |> Map.put(:signal_type, signal_type)
  end

  defp send_signal_to_sender(binary_payload, from) do
    SignalCommunication.outbouce(from, binary_payload)
  end
end
