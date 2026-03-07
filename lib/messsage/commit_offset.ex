defmodule Commit.Offset do
  @moduledoc """
  Handles OffsetCommit acknowledgments and prepares OffsetCommit response messages.
  """

  @route_id 7
  alias Route.Connect
  alias Bimip.{MessageScheme, OffsetCommit}

  @ack_type 2
  @reject_type 3

  @spec offset_commit(%{
          offset_commit: MessageScheme.t(),
          device_id: String.t(),
          uupid: any()
        }) :: any()
  def offset_commit(%{offset_commit: offset_commit, device_id: device_id, uupid: uupid}) do
    {:offset_commit, %OffsetCommit{} = data} = offset_commit.payload

    type =
      case Queue.QueueLogImpl.acknowledge(data.from.eid, uupid, data.offset) do
        :ok -> @ack_type
        _ -> @reject_type
      end

    data
    |> update_type(type)
    |> build_message()
    |> MessageScheme.encode()
    |> then(&Connect.outbouce(device_id, &1))
  end

  defp update_type(%OffsetCommit{} = payload, type) when type in [@ack_type, @reject_type] do
    Map.put(payload, :type, type)
  end

  defp build_message(payload) do
    %MessageScheme{
      route_id: @route_id,
      payload: {:offset_commit, payload}
    }
  end
end
