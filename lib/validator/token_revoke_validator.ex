# defmodule Bimip.Validators.TokenRevokeValidator do
#   alias Bimip.Protos.TokenRevoke

#   @client_allowed_phase 2

#   def validate_token_revoke(%TokenRevoke{} = msg, eid, device_id) do
#     cond do
#       # Check if `to` is provided
#       is_nil(msg.to) ->
#         {:error, error_detail(100, "Missing target identity", "to")}

#       # Check if `to.eid` exists
#       is_nil(msg.to.eid) or msg.to.eid == "" ->
#         {:error, error_detail(100, "Missing 'to.eid'", "to.eid")}

#       # Check if `to.connection_resource_id` exists
#       is_nil(msg.to.connection_resource_id) or msg.to.connection_resource_id == "" ->
#         {:error, error_detail(100, "Missing 'to.connection_resource_id'", "to.connection_resource_id")}

#       # Only client can send REQUEST phase
#       msg.phase != @client_allowed_phase ->
#         {:error, error_detail(100, "Invalid phase: client may only send phase=2 (SUBMIT)", "phase")}

#       # Token must be provided
#       is_nil(msg.token) or msg.token == "" ->
#         {:error, error_detail(100, "Token must be provided in request phase", "token")}

#       # Validate `to.eid` matches this session
#       msg.to.eid != eid ->
#         {:error, error_detail(401, "EID mismatch — possible forged message", "to.eid")}

#       # Validate connection resource matches session device
#       msg.to.connection_resource_id != device_id ->
#         {:error, error_detail(401, "Invalid connection resource", "to.connection_resource_id")}

#       true ->
#         :ok
#     end
#   end

#   defp error_detail(code, description, field),
#     do: %{code: code, description: description, field: field}
# end
