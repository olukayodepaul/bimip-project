defmodule Bimip.Validators.LogoutValidator do
  alias Bimip.Logout

  # Entry function for logout message validation
  def validate_logout(%Logout{} = msg) do
    cond do
      # Validate `to` field
      is_nil(msg.to) or msg.to.eid in [nil, ""] or msg.to.connection_resource_id in [nil, ""] ->
        {:error, error_detail(100, "Invalid 'to' identity", "to")}

      # Validate `type` (must be 1 = REQUEST)
      msg.type != 1 ->
        {:error, error_detail(100, "Invalid 'type' (must be 1 for REQUEST)", "type")}

      # Validate `status` (must be 4 = PENDING)
      msg.status != 4 ->
        {:error, error_detail(100, "Invalid 'status' (must be 4 for Logout REQUEST)", "status")}

      # Validate `timestamp`
      is_nil(msg.timestamp) or msg.timestamp <= 0 ->
        {:error, error_detail(100, "Missing or invalid 'timestamp'", "timestamp")}

      true ->
        :ok
    end
  end

  # Helper to standardize error formatting
  defp error_detail(code, description, field) do
    %{
      code: code,
      description: description,
      field: field
    }
  end
end
