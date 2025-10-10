# defmodule ThrowTokenRefreshSchema do
#   @moduledoc """
#   Builds TokenRefresh stanzas for both RESULT (success) and ERROR (inline).
#   """

#   # Standard RESULT response (phase = 2)
#   def result(to_eid, to_device_id, refresh_token \\ "") do
#     build(to_eid, to_device_id, refresh_token, 2)
#   end

#   # Inline ERROR response (phase = 3)
#   def error(to_eid, to_device_id, reason) do
#     build(to_eid, to_device_id, "", 3, reason)
#   end

#   # Internal builder for REQUEST/RESULT/ERROR
#   defp build(to_eid, to_device_id, refresh_token, phase, reason \\ "") do
#     token_refresh = %Bimip.TokenRefresh{
#       to: %Bimip.Identity{
#         eid: to_eid,
#         connection_resource_id: to_device_id
#       },
#       refresh_token: refresh_token,
#       phase: phase,
#       timestamp: System.system_time(:millisecond),
#       # Optionally carry reason for ERROR
#       reason: reason
#     }

#     %Bimip.MessageScheme{
#       route: 5, # assign proper route for TokenRefresh
#       payload: {:token_refresh, token_refresh}
#     }
#     |> Bimip.MessageScheme.encode()
#   end
# end
