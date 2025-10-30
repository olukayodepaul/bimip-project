defmodule Bimip.Validators.AwarenessVisibilityValidator do
  @moduledoc """
  Validates an AwarenessVisibility message.

  Validation Rules:
    - `id` must be a non-empty binary string (used to reconcile request/response)
    - `from` identity must exist and contain `connection_resource_id`
    - `type` must be one of:
        1 = ENABLED
        2 = DISABLED
        3 = ERROR
    - `timestamp` must be a positive integer (Unix UTC ms)
    - `details` is optional but, if present, must be a binary
  """

  alias Bimip.AwarenessVisibility

  @allowed_types [1, 2, 3]

  @spec validate(AwarenessVisibility.t(), String.t(), String.t()) :: :ok | {:error, map()}
  def validate(%AwarenessVisibility{} = msg, eid, device_id) do
    with :ok <- validate_id(msg.id),
         :ok <- validate_identity(msg.from, "from"),
         :ok <- validate_type(msg.type),
         :ok <- validate_timestamp(msg.timestamp),
         :ok <- validate_details(msg.details) do
      :ok
    end
  end

  # ---------------- ID Validation ----------------
  defp validate_id(nil),
    do: {:error, error_detail(100, "Missing id field", "id")}

  defp validate_id(id) when is_binary(id) and byte_size(id) > 0, do: :ok

  defp validate_id(_),
    do: {:error, error_detail(100, "Invalid id — must be a non-empty string", "id")}

  # ---------------- Identity Validation ----------------
  defp validate_identity(nil, field),
    do: {:error, error_detail(100, "Missing #{field} identity", field)}

  defp validate_identity(%{connection_resource_id: nil}, field),
    do: {:error, error_detail(100, "Missing #{field}.connection_resource_id", "#{field}.connection_resource_id")}

  defp validate_identity(%{connection_resource_id: ""}, field),
    do: {:error, error_detail(100, "Empty #{field}.connection_resource_id", "#{field}.connection_resource_id")}

  defp validate_identity(_identity, _field), do: :ok

  # ---------------- Type Validation ----------------
  defp validate_type(t) when t in @allowed_types, do: :ok

  defp validate_type(_),
    do: {:error, error_detail(100, "Invalid type — must be 1 = ENABLED, 2 = DISABLED, or 3 = ERROR", "type")}

  # ---------------- Timestamp Validation ----------------
  defp validate_timestamp(ts) when is_integer(ts) and ts > 0, do: :ok

  defp validate_timestamp(_),
    do: {:error, error_detail(100, "Missing or invalid timestamp", "timestamp")}

  # ---------------- Details (optional text) ----------------
  defp validate_details(nil), do: :ok
  defp validate_details(details) when is_binary(details), do: :ok

  defp validate_details(_),
    do: {:error, error_detail(100, "details must be a string if provided", "details")}

  # ---------------- Error Helper ----------------
  defp error_detail(code, description, field),
    do: %{code: code, description: description, field: field}
end
