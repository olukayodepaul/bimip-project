defmodule Bimip.Validators.LogoutValidator do
  alias Bimip.Logout

  @doc """
  Validates a logout request stanza.
  Ensures that all required fields exist and that the message
  targets the correct `eid` and `device_id` for this GenServer.
  """
  def validate_logout(%Logout{} = msg, eid, device_id) do
    cond do
      # Ensure `to` identity exists and has valid IDs
      is_nil(msg.to) or msg.to.eid in [nil, ""] or msg.to.connection_resource_id in [nil, ""] ->
        {:error, error_detail(100, "Invalid 'to' identity", "to")}

      # Ensure target identity matches the connected client
      msg.to.eid != eid ->
        {:error, error_detail(101, "EID mismatch: not authorized target", "to.eid")}

      msg.to.connection_resource_id != device_id ->
        {:error, error_detail(102, "Resource ID mismatch: not authorized target", "to.connection_resource_id")}

      # Only REQUEST is accepted from client
      msg.type != 1 ->
        {:error, error_detail(103, "Invalid 'type' (must be 1=REQUEST)", "type")}

      # Logout request should be pending
      msg.status != 4 ->
        {:error, error_detail(104, "Invalid 'status' (must be 4=PENDING for request)", "status")}

      # Timestamp required and positive
      is_nil(msg.timestamp) or msg.timestamp <= 0 ->
        {:error, error_detail(105, "Missing or invalid 'timestamp'", "timestamp")}

      true ->
        :ok
    end
  end

  defp error_detail(code, description, field),
    do: %{code: code, description: description, field: field}
end
