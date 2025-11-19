defmodule Chat.ResumeSignal do
  alias Queue.Injection
  alias Until.UniPosTime

  @partition_id 1

  def resume(%Chat.ResumeStruct{
        from: %{eid: from_eid, connection_resource_id: device_id},
        to: %{eid: to_eid}
      } = _payload) do

    queue_id = "#{from_eid}_#{to_eid}"

    case Injection.fetch_messages(queue_id, device_id, @partition_id) do
      {:ok, %{messages: [message]}} ->
        message
        |> set_message_fields()
        |> Map.put(:signal_offset_state, false)
        |> Map.put(:timestamp, UniPosTime.uni_pos_time())
        |> then(&IO.inspect(&1))


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

    %{
      id: id,
      from: from,
      to: to,
      payload: payload,
      encryption_type: encryption_type,
      encrypted: encrypted,
      signature: signature,
      user_offset: user_offset,
      signal_offset: signal_offset,
      signal_type: signal_type,
      signal_ack_state:
        Injection.get_ack_status(
          "#{from.eid}_#{to.eid}",
          from.connection_resource_id,
          @partition_id,
          signal_offset
        )
    }
  end
end

  # def build_message(
  #   %{
  #     id: id,
  #     from: %{eid: from_eid, connection_resource_id: from_device_id},
  #     to: %{eid: to_eid, connection_resource_id: to_device_id},
  #     payload: payload,
  #     encryption_type: encryption_type,
  #     encrypted: encrypted,

  #     signature: signature,
  #     signal_type: signal_type,

  #     user_offset: user_offset,
  #     signal_offset: signal_offset,

  #     signal_offset_state: signal_offset_state,
  #     signal_ack_state: %{read: read, sent: sent, delivered: delivered},
  #     timestamp:  timestamp
  #     }) do
