defmodule Bimip.Validators.MessageValidator do
  @moduledoc """
  Validates a Message stanza and returns errors mapped to your standard status_code table.
  """

  alias Bimip.Message
  alias Bimip.Identity

  # ---------------- Status Codes ----------------
  @status_ok               200
  @status_processed        201
  @status_read             202

  @status_moved            301
  @status_queued           304

  @status_bad_request      400
  @status_unauthorized     401
  @status_blocked          403
  @status_not_found        404
  @status_timeout          408
  @status_out_of_order     409
  @status_invalid_encrypt  410

  @status_internal_error   500
  @status_unavailable      503

  @spec validate(Message.t()) :: :ok | {:error, map()}
  def validate(%Message{} = msg) do
    with :ok <- validate_id(msg.peer_uid),
         :ok <- validate_identity(msg.from, "from"),
         :ok <- validate_identity(msg.to, "to"),
         :ok <- validate_from_to_not_same(msg.from, msg.to),
         :ok <- validate_timestamp(msg.timestamp),
         :ok <- validate_payload(msg.payload),
         :ok <- validate_encryption_type(msg.encryption_type),
         :ok <- validate_binary_field(msg.encrypted, "encrypted"),
         :ok <- validate_binary_field(msg.signature, "signature") do
      :ok
    end
  end

  # ---------------- ID Validation ----------------
  defp validate_id(nil),
    do: error(@status_bad_request, "Missing peer_uid", "peer_uid")

  defp validate_id(id) when is_binary(id) and byte_size(id) > 0, do: :ok

  defp validate_id(_),
    do: error(@status_bad_request, "Invalid peer_uid — must be non-empty string", "peer_uid")

  # ---------------- Identity Validation ----------------
  defp validate_identity(nil, field),
    do: error(@status_bad_request, "Missing #{field} identity", field)

  defp validate_identity(%Identity{} = ident, field) do
    cond do
      not (is_binary(ident.eid) and byte_size(ident.eid) > 0) ->
        error(@status_bad_request, "Invalid #{field}.eid — must be non-empty", "#{field}.eid")

      ident.connection_resource_id != nil and
          not is_binary(ident.connection_resource_id) ->
        error(
          @status_bad_request,
          "#{field}.connection_resource_id must be binary",
          "#{field}.connection_resource_id"
        )

      ident.node != nil and not is_binary(ident.node) ->
        error(
          @status_bad_request,
          "#{field}.node must be binary",
          "#{field}.node"
        )

      true ->
        :ok
    end
  end

  defp validate_identity(_, field),
    do: error(@status_bad_request, "Malformed #{field} identity", field)

  # ---------------- Cross Identity Validation ----------------
  defp validate_from_to_not_same(%Identity{eid: eid}, %Identity{eid: eid}) do
    error(
      @status_bad_request,
      "`from.eid` and `to.eid` cannot be the same",
      "from,to"
    )
  end

  defp validate_from_to_not_same(_, _), do: :ok

  # ---------------- Timestamp ----------------
  defp validate_timestamp(ts) when is_integer(ts) and ts > 0, do: :ok

  defp validate_timestamp(_),
    do: error(@status_bad_request, "Invalid timestamp", "timestamp")

  # ---------------- Payload (JSON) ----------------
  defp validate_payload(payload) when is_binary(payload) do
    case Jason.decode(payload) do
      {:ok, _} ->
        :ok

      {:error, _} ->
        error(@status_bad_request, "Payload must be valid JSON", "payload")
    end
  end

  defp validate_payload(_),
    do: error(@status_bad_request, "Payload must be binary JSON", "payload")

  # ---------------- Optional Binary Fields ----------------
  defp validate_binary_field(nil, _), do: :ok
  defp validate_binary_field(val, _field) when is_binary(val), do: :ok

  defp validate_binary_field(_, field),
    do: error(@status_bad_request, "#{field} must be binary if provided", field)

  # ---------------- Encryption Type ----------------
  defp validate_encryption_type(enc) when is_binary(enc) and byte_size(enc) > 0,
    do: :ok

  defp validate_encryption_type(_),
    do: error(@status_invalid_encrypt, "Missing or invalid encryption_type", "encryption_type")

  # ---------------- Message Type ----------------
  defp validate_type(t) when is_integer(t), do: :ok

  defp validate_type(_),
    do: error(@status_bad_request, "Invalid message type", "type")

  # ---------------- Transmission Mode ----------------
  defp validate_transmission_mode(t) when is_integer(t), do: :ok

  defp validate_transmission_mode(_),
    do: error(@status_bad_request, "Invalid transmission_mode", "transmission_mode")

  # ---------------- Error Helper ----------------
  defp error(code, description, field),
    do: {:error, %{code: code, description: description, field: field}}
end
