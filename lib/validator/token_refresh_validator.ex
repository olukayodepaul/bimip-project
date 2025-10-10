# defmodule Bimip.Validators.TokenRefreshValidator do
#   alias Bimip.Protos.TokenRefresh

#   @client_allowed_phase 1

#   @doc """
#   Validates a TokenRefresh message sent from client.

#   Checks:
#     - `to` identity exists and matches the current session
#     - `phase` is 1 (REQUEST)
#     - `refresh_token` is provided
#     - `timestamp` is positive
#   """
#   def validate_token_refresh(%TokenRefresh{} = msg, eid, device_id) do
#     cond do
#       # Validate target identity
#       msg.to == nil ->
#         {:error, error_detail(100, "Missing target identity", "to")}

#       is_nil(msg.to.eid) or msg.to.eid == "" ->
#         {:error, error_detail(100, "Missing EID in target identity", "to.eid")}

#       is_nil(msg.to.connection_resource_id) or msg.to.connection_resource_id == "" ->
#         {:error, error_detail(100, "Missing connection_resource_id in target identity", "to.connection_resource_id")}

#       # Validate phase: client can only send 1 = REQUEST
#       msg.phase != @client_allowed_phase ->
#         {:error, error_detail(100, "Invalid phase: client may only send phase=1 (REQUEST)", "phase")}

#       # Validate refresh token
#       is_nil(msg.refresh_token) or msg.refresh_token == "" ->
#         {:error, error_detail(100, "Missing refresh_token", "refresh_token")}

#       # Validate timestamp
#       is_nil(msg.timestamp) or msg.timestamp <= 0 ->
#         {:error, error_detail(100, "Missing or invalid timestamp", "timestamp")}

#       # Validate session match
#       msg.to.eid != eid or msg.to.connection_resource_id != device_id ->
#         {:error, error_detail(401, "EID or device_id mismatch — unauthorized sender", "to")}

#       true ->
#         :ok
#     end
#   end

#   defp error_detail(code, description, field),
#     do: %{code: code, description: description, field: field}
# end
