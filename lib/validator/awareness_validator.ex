defmodule Bimip.Validators.AwarenessValidator do
  @moduledoc """
  Validates an Awareness message sent from a client.

  Validation Rules:
  - `from` and `to`: must exist and contain `connection_resource_id`
  - `type`: must be 1 (REQUEST)
  - `status`: must be between 1 and 7
  - `location_sharing`: must be 1 (ENABLED) or 2 (DISABLED)
  - If `location_sharing = 1`, both `latitude` and `longitude` must be valid numbers
  - If `location_sharing = 2`, both may be omitted
  - `ttl`: must be a positive integer
  - `timestamp`: must be a positive integer (epoch millis)
  """

  alias Bimip.Awareness

  @allowed_status 1..7
  @allowed_location_sharing [1, 2]
  @allowed_type 1 # REQUEST only

  @spec validate_awareness(Awareness.t()) :: :ok | {:error, map()}
  def validate_awareness(%Awareness{} = msg) do
    with :ok <- validate_identity(msg.from, "from"),
        :ok <- validate_identity(msg.to, "to"),
        :ok <- validate_type(msg.type),
        :ok <- validate_status(msg.status),
        :ok <- validate_location_sharing(msg.location_sharing),
        :ok <- validate_coordinates(msg.location_sharing, msg.latitude, msg.longitude),
        :ok <- validate_ttl(msg.ttl),
        :ok <- validate_timestamp(msg.timestamp) do
      :ok
    end
  end

  # ------------------------------------------------------------------------
  # Field validations
  # ------------------------------------------------------------------------

  defp validate_identity(nil, field),
    do: {:error, error_detail(100, "Missing #{field} identity", field)}

  defp validate_identity(%{connection_resource_id: id}, field)
      when id in [nil, ""],
      do: {:error, error_detail(100, "Missing #{field}.connection_resource_id", "#{field}.connection_resource_id")}

  defp validate_identity(_identity, _field), do: :ok

  defp validate_type(@allowed_type), do: :ok
  defp validate_type(_),
    do: {:error, error_detail(100, "Invalid type — user can only send REQUEST (1)", "type")}

  defp validate_status(status) when status in @allowed_status, do: :ok
  defp validate_status(_),
    do: {:error, error_detail(100, "Invalid status — must be between 1 and 7", "status")}

  defp validate_location_sharing(v) when v in @allowed_location_sharing, do: :ok
  defp validate_location_sharing(_),
    do: {:error, error_detail(100, "Invalid location_sharing — must be 1 or 2", "location_sharing")}

  defp validate_ttl(ttl) when is_integer(ttl) and ttl > 0, do: :ok
  defp validate_ttl(_),
    do: {:error, error_detail(100, "Missing or invalid ttl", "ttl")}

  defp validate_timestamp(ts) when is_integer(ts) and ts > 0, do: :ok
  defp validate_timestamp(_),
    do: {:error, error_detail(100, "Missing or invalid timestamp", "timestamp")}

  # ------------------------------------------------------------------------
  # Conditional Coordinate Validation
  # ------------------------------------------------------------------------

  # When location_sharing = ENABLED (1), coordinates must be valid numbers
  defp validate_coordinates(1, lat, lon) do
    cond do
      is_nil(lat) or is_nil(lon) ->
        {:error, error_detail(100, "Latitude and Longitude required when sharing is enabled", "coordinates")}

      not is_number(lat) or not is_number(lon) ->
        {:error, error_detail(100, "Latitude and Longitude must be numeric when sharing is enabled", "coordinates")}

      true ->
        :ok
    end
  end

  # When location_sharing = DISABLED (2), coordinates are optional
  defp validate_coordinates(2, _lat, _lon), do: :ok

  # Fallback (shouldn't happen if location_sharing validated earlier)
  defp validate_coordinates(_, _lat, _lon),
    do: {:error, error_detail(100, "Invalid location_sharing value", "location_sharing")}

  # ------------------------------------------------------------------------
  # Error helper
  # ------------------------------------------------------------------------
  defp error_detail(code, description, field),
    do: %{code: code, description: description, field: field}
end
