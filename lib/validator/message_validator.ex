defmodule Bimip.Validators.MessageValidator do
  @moduledoc """
  Validates a Message stanza for client-to-server sending.

  Rules:
    - `id` must be a non-empty binary
    - `from` and `to` identities must exist and contain valid `eid` and `connection_resource_id`
    - `type` must be integer: 1=Chat, 2=PushNotification
    - `status` must be 1 (SENT) for new messages
    - `timestamp` must be a positive integer (Unix UTC ms)
    - `payload` must be binary and valid JSON
    - `encryption_type` must be a non-empty binary
    - `encrypted` and `signature` are optional binaries
    - `signal_type` must be 2 (TWO-WAY)
  """

  alias Bimip.Message

  @allowed_types [1, 2]      # 1=Chat, 2=PushNotification
  @allowed_status 1           # Only SENT is allowed for new messages
  @allowed_signal_type 2      # TWO-WAY

  @spec validate(Message.t()) :: :ok | {:error, map()}
  def validate(%Message{} = msg) do
    with :ok <- validate_id(msg.id),
         :ok <- validate_identity(msg.from, "from"),
         :ok <- validate_identity(msg.to, "to"),
         :ok <- validate_type(msg.type),
         :ok <- validate_status(msg.status),
         :ok <- validate_timestamp(msg.timestamp),
         :ok <- validate_payload(msg.payload),
         :ok <- validate_binary_field(msg.encrypted, "encrypted"),
         :ok <- validate_binary_field(msg.signature, "signature"),
         :ok <- validate_encryption_type(msg.encryption_type),
         :ok <- validate_signal_type(msg.signal_type) do
      :ok
    end
  end

  # ---------------- ID Validation ----------------
  defp validate_id(nil),
    do: {:error, error_detail(100, "Missing id field", "id")}
  defp validate_id(id) when is_binary(id) and byte_size(id) > 0, do: :ok
  defp validate_id(_),
    do: {:error, error_detail(100, "Invalid id — must be non-empty string", "id")}

  # ---------------- Identity Validation ----------------
  defp validate_identity(nil, field),
    do: {:error, error_detail(102, "Missing #{field} identity", field)}

  defp validate_identity(%{eid: eid, connection_resource_id: crid}, field) do
    cond do
      not (is_binary(eid) and byte_size(eid) > 0) ->
        {:error, error_detail(103, "Invalid #{field}.eid — must be non-empty string", "#{field}.eid")}

      not (is_binary(crid) and byte_size(crid) > 0) ->
        {:error, error_detail(104, "Invalid #{field}.connection_resource_id — must be non-empty string", "#{field}.connection_resource_id")}

      true ->
        :ok
    end
  end

  defp validate_identity(_, field),
    do: {:error, error_detail(105, "Malformed #{field} identity", field)}

  # ---------------- Type Validation ----------------
  defp validate_type(t) when t in @allowed_types, do: :ok
  defp validate_type(_),
    do: {:error, error_detail(106, "Invalid type — must be 1=Chat or 2=PushNotification", "type")}

  # ---------------- Status Validation ----------------
  defp validate_status(s) when s == @allowed_status, do: :ok
  defp validate_status(_),
    do: {:error, error_detail(107, "Invalid status — must be 1=SENT for new messages", "status")}

  # ---------------- Timestamp Validation ----------------
  defp validate_timestamp(ts) when is_integer(ts) and ts > 0, do: :ok
  defp validate_timestamp(_),
    do: {:error, error_detail(108, "Missing or invalid timestamp", "timestamp")}

  # ---------------- Payload Validation ----------------
  defp validate_payload(payload) when is_binary(payload) do
    case Jason.decode(payload) do
      {:ok, _json} -> :ok
      {:error, _} -> {:error, error_detail(109, "Payload must be valid JSON", "payload")}
    end
  end
  defp validate_payload(_),
    do: {:error, error_detail(109, "Payload must be a binary", "payload")}

  # ---------------- Optional Binary Fields ----------------
  defp validate_binary_field(nil, _), do: :ok
  defp validate_binary_field(val, _field) when is_binary(val), do: :ok
  defp validate_binary_field(_, field),
    do: {:error, error_detail(110, "#{field} must be a binary if provided", field)}

  # ---------------- Encryption Type ----------------
  defp validate_encryption_type(enc) when is_binary(enc) and byte_size(enc) > 0, do: :ok
  defp validate_encryption_type(_),
    do: {:error, error_detail(111, "Missing or invalid encryption_type", "encryption_type")}

  # ---------------- Signal Type Validation ----------------
  defp validate_signal_type(@allowed_signal_type), do: :ok
  defp validate_signal_type(_),
    do: {:error, error_detail(112, "Invalid signal_type — must be 2=TWO-WAY", "signal_type")}

  # ---------------- Error Helper ----------------
  defp error_detail(code, description, field),
    do: %{code: code, description: description, field: field}
end
