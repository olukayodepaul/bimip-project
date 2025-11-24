# defmodule BimipRPCClient do

#   require Logger
#   alias BimipServer.BimipService.Stub
#   alias BimipServer.AwarenessVisibilityReq

#   @route Application.get_env(:bimip, :syste_route)[:route]

#   def awareness_visibility({id, eid, device_id, type, timestamp}) do


#     {:ok, channel} = GRPC.Stub.connect(@route)

#     case Stub.awareness_visibility(channel, visibility_model({id, eid, device_id, type, timestamp})) do
#       {:ok, res} ->
#         Logger.info("✅ Resp: #{inspect(res)}")
#         {:ok, res}

#       {:error, reason} ->
#         Logger.error("❌ GRPC Error: #{inspect(reason)}")
#         {:error, reason}
#     end
#   end

#   def visibility_model({id, eid, device_id, type, timestamp}) {
#     %AwarenessVisibilityReq{
#       id: id,
#       eid: eid,
#       device_id: device_id,
#       type: type,
#       timestamp: timestamp
#     }
#   }
# end
