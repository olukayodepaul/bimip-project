defmodule Chat.ResumeSignal do
  alias Queue.Injection
  alias Until.UniPosTime
  alias ThrowMessageSchema
  alias Route.SignalCommunication
  alias Bimip.{Message, MessageScheme, Identity, Body}

  @partition_id 1
  @signal_request 2
  @limit 1

  def resume(%Chat.SignalStruct{
        from: %Chat.EntityStruct{eid: eid_from},
        eid: eid,
        device: device
      }) do

    queue_id = "#{eid_from}"

    case Injection.fetch_messages(queue_id, device, @partition_id, 1) do
      {:ok, %{messages: messages}} when is_list(messages) and messages != [] ->

        build_bulk_message(messages)

      {:ok, %{messages: []}} ->
        :ok

      {:error, reason} ->
        :ok
    end
  end
end
