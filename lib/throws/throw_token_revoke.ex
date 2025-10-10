# defmodule ThrowTokenRevokeSchema do
#   @moduledoc """
#   Builds TokenRevoke stanzas for both success (RESULT) and error.
#   """

#   # Standard RESULT response
#   def result(to_eid, to_device_id, reason \\ "") do
#     build(to_eid, to_device_id, "", 2, reason)
#   end

#   # Inline ERROR response
#   def error(to_eid, to_device_id, reason) do
#     build(to_eid, to_device_id, "", 3, reason)
#   end

#   # Internal builder for REQUEST/RESULT/ERROR
#   defp build(to_eid, to_device_id, token, phase, reason) do
#     token_revoke = %Bimip.TokenRevoke{
#       to: %Bimip.Identity{eid: to_eid, connection_resource_id: to_device_id},
#       token: token,
#       phase: phase,
#       timestamp: System.system_time(:millisecond),
#       reason: reason
#     }

#     %Bimip.MessageScheme{
#       route: 4, # assign proper route
#       payload: {:token_revoke, token_revoke}
#     }
#     |> Bimip.MessageScheme.encode()
#   end
# end
