defmodule BimipClient do
  require Logger
  alias BimipServer.BimipService.Stub
  alias BimipServer.AwarenessVisibilityReq

  def awareness_visibility(id, eid, device_id, type, timestamp) do

    req = %AwarenessVisibilityReq{
      id: id,
      eid: eid,
      device_id: device_id,
      type: 1,
      timestamp: timestamp
    }

    {:ok, channel} = GRPC.Stub.connect("localhost:50051")

    case Stub.awareness_visibility(channel, req) do
      {:ok, res} ->
        Logger.info("✅ Responseeeeeeeeeess: #{inspect(res)}")
        {:ok, res}

      {:error, reason} ->
        Logger.error("❌ GRPC Error: #{inspect(reason)}")
        {:error, reason}
    end
  end
end
