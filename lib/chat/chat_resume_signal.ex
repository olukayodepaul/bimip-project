defmodule Chat.ResumeSignal do
  alias Queue.Injection
  alias ThrowMessageSchema
  alias Route.Connect

  @partition_id 1
  @limit 100

  def resume(%Chat.SignalStruct{
        eid: eid,
        device: device
      }) do

    case Injection.fetch_messages(eid, device, @partition_id, @limit) do
      {:ok, %{messages: messages}} when is_list(messages) and messages != [] ->

        ThrowMessageSchema.build_bulk_message(messages)
        |> then(&Connect.outbouce(device, &1))

      {:ok, %{messages: []}} ->
        :ok

      {:error, _reason} ->
        :ok
    end
  end
end
