defmodule Bimip.Validators.MessageValidator do
  @moduledoc """
  Production-grade validation for Message protobuf.

  Enforces:
  - Strict UUID validation
  - Replay window timestamp validation
  - Enum constraints
  - Payload size limits
  """

  alias Bimip.Message
  alias Bimip.Identity

  # ---------------- Status Codes ----------------
  @status_bad_request      400
  @status_out_of_order     409
  @status_invalid_encrypt  410

  # ---------------- Protocol Constraints ----------------
  @max_payload_size 1_048_576        # 1 MB
  @replay_window_ms 300_000          # 5 minutes
  @uuid_v4_regex ~r/^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i

  # ---------------- Public API ----------------
  @spec validate(Message.t()) :: :ok | {:error, map()}
  def validate(%Message{} = msg) do
    with :ok <- validate_id(msg.id),
         :ok <- validate_identity(msg.from, "from"),
         :ok <- validate_identity(msg.to, "to"),
         :ok <- validate_from_to_not_same(msg.from, msg.to),
         :ok <- validate_timestamp(msg.timestamp),
         :ok <- validate_payload(msg.payload),
         :ok <- validate_required_int32(msg.content_type, "content_type"),
         :ok <- validate_content_type(msg.content_type),
         :ok <- validate_required_int32(msg.participant_role, "participant_role"),
         :ok <- validate_participant_role(msg.participant_role),
         :ok <- validate_optional_int32(msg.delivery_type, "delivery_type"),
         :ok <- validate_binary_required(msg.ephemeral_public_key, "ephemeral_public_key"),
         :ok <- validate_binary_required(msg.mac, "mac"),
         :ok <- validate_required_int32(msg.message_type, "message_type") do
      :ok
    end
  end

  # ---------------- Strict UUID ----------------
  defp validate_id(id) when is_binary(id) do
    if Regex.match?(@uuid_v4_regex, id) do
      :ok
    else
      error(@status_bad_request, "id must be valid UUID v4", "id")
    end
  end

  defp validate_id(_),
    do: error(@status_bad_request, "id must be non-empty UUID string", "id")

  # ---------------- Identity ----------------
  defp validate_identity(%Identity{} = ident, field) do
    cond do
      not (is_binary(ident.eid) and byte_size(ident.eid) > 0) ->
        error(@status_bad_request, "#{field}.eid must be non-empty", "#{field}.eid")

      true ->
        :ok
    end
  end

  defp validate_identity(_, field),
    do: error(@status_bad_request, "Malformed #{field} identity", field)

  # ---------------- from != to ----------------
  defp validate_from_to_not_same(%Identity{eid: eid}, %Identity{eid: eid}) do
    error(@status_bad_request, "`from.eid` and `to.eid` cannot be same", "from,to")
  end

  defp validate_from_to_not_same(_, _), do: :ok

  # ---------------- Replay Window ----------------
  defp validate_timestamp(timestamp) when is_integer(timestamp) do
    now = System.system_time(:millisecond)
    max_age = 30 * 60 * 1000  # 30 minutes

    if now - timestamp > max_age do
      error(@status_out_of_order, "timestamp expired (older than 30 minutes)", "timestamp")
    else
      :ok
    end
  end


  defp validate_timestamp(_),
    do: error(@status_bad_request, "timestamp must be positive int64", "timestamp")

  # ---------------- Payload ----------------
  defp validate_payload(payload) when is_binary(payload) do
    cond do
      byte_size(payload) == 0 ->
        error(@status_bad_request, "payload cannot be empty", "payload")

      byte_size(payload) > @max_payload_size ->
        error(@status_bad_request, "payload exceeds maximum allowed size", "payload")

      true ->
        :ok
    end
  end

  defp validate_payload(_),
    do: error(@status_bad_request, "payload must be bytes", "payload")

  # ---------------- Content Type (Required 1..4) ----------------
  defp validate_content_type(type) when type in 1..4,
    do: :ok

  defp validate_content_type(_),
    do:
      error(
        @status_bad_request,
        "content_type must be 1(TEXT),2(AUDIO),3(VIDEO),4(FILE)",
        "content_type"
      )

  # ---------------- Participant Role (Ingress Must Be SENDER) ----------------
  defp validate_participant_role(1), do: :ok

  defp validate_participant_role(_),
    do:
      error(
        @status_bad_request,
        "participant_role must be 1 (SENDER) at ingress",
        "participant_role"
      )

  # ---------------- Optional delivery_type ----------------
  defp validate_optional_int32(nil, _), do: :ok
  defp validate_optional_int32(val, _) when is_integer(val), do: :ok
  defp validate_optional_int32(_, field),
    do: error(@status_bad_request, "#{field} must be int32 if provided", field)

  # ---------------- Required Int32 ----------------
  defp validate_required_int32(val, _) when is_integer(val), do: :ok
  defp validate_required_int32(_, field),
    do: error(@status_bad_request, "#{field} must be int32", field)

  # ---------------- Required Binary ----------------
  defp validate_binary_required(val, _) when is_binary(val) and byte_size(val) > 0,
    do: :ok

  defp validate_binary_required(_, field),
    do: error(@status_invalid_encrypt, "#{field} must be non-empty bytes", field)

  # ---------------- Error Helper ----------------
  defp error(code, description, field),
    do: {:error, %{code: code, description: description, field: field}}
end
