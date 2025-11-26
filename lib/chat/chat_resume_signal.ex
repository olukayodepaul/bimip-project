defmodule Chat.ResumeSignal do
  alias Queue.Injection
  alias Until.UniPosTime
  alias ThrowMessageSchema
  alias Route.SignalCommunication

  @partition_id 1
  @signal_request 2
  @limit 2

  def resume(%Chat.SignalStruct{
        from: %Chat.EntityStruct{eid: eid_from},
        eid: eid,
        device: device
      }) do

    queue_id = "#{eid_from}"

    IO.inspect(Injection.fetch_messages(queue_id, device, @partition_id, @limit) )

    # case Injection.fetch_messages(queue_id, device, @partition_id, @limit) do
    #   {:ok, %{messages: messages}} when is_list(messages) and messages != [] ->

    #     lady = messages
    #     |> Stream.map(fn %{payload: payload} -> payload end)
    #     # |> Stream.each(fn payload ->
    #     #   payload
    #     # end)
    #     |> Stream.run()
    #     |> Enum.to_list()


    #     IO.inspect(lady)

    #   {:ok, %{messages: []}} ->
    #     IO.puts("No messages found for this batch")

    #   {:error, reason} ->
    #     IO.puts("Failed to fetch messages: #{inspect(reason)}")
    # end

  end


  # ----------------------
  # Helpers
  # ----------------------
  defp get_ack_status(user, device, partition, offset), do: Injection.get_ack_status(user, device, partition, offset)
  defp confirm_advance_offset(user, device, partition, offset), do: Injection.confirm_advance_offset(user, device, partition, offset)
  defp publish_pull_message(binary_payload, from), do: SignalCommunication.outbouce(from, binary_payload)
  defp signal_type(message_eid, eid), do: if(message_eid == eid, do: 2, else: 3)

  # ----------------------
  # Prepare payload fields
  # ----------------------
  defp set_message_fields(payload, queue_id, eid, device_id) do

    %{read: read, sent: sent, delivered: delivered} = get_ack_status(queue_id, device_id, @partition_id, payload.signal_offset)
    adv = confirm_advance_offset(queue_id, device_id, @partition_id, payload.signal_offset)

    payload
    |> Map.put(:to, %{eid: eid, connection_resource_id: device_id})
    |> Map.put(:from, payload.from)
    |> Map.put(:user_offset, String.to_integer(payload.user_offset))
    |> Map.put(:signal_offset, String.to_integer(payload.signal_offset))
    |> Map.put(:signal_type, signal_type(payload.from.eid, eid))
    |> Map.put(:signal_request, @signal_request)
    |> Map.put(:owner, payload.from)
    |> Map.put(:timestamp, UniPosTime.uni_pos_time())
    |> Map.put(:signal_ack_state, %{send: true, delivered: false, read: false, advance_offset: adv})

  end


end
