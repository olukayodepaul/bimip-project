defmodule Bimip.Validators.PingValidator do
  @moduledoc """
  Production-grade validation for Ping protobuf.

  message Ping {
      string id = 1;
      Identity from = 2;
      int32 type = 3;   # Allowed: 1 or 2
      int64 timestamp = 4;
  }

  This validator enforces ONLY type = 1.
  """

  alias Bimip.Ping
  alias Bimip.Identity

  # ---------------- Status Codes ----------------
  @status_bad_request 400
  @status_unauthorized 401
  @status_out_of_order 409

  # ---------------- Protocol Constraints ----------------
  @expected_type 1
  @allowed_types [1, 2]
  @uuid_v4_regex ~r/^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i
  @replay_window_ms 300_000  # 5 minutes

  # ---------------- Public API ----------------
  @spec validate(Ping.t(), String.t()) :: :ok | {:error, map()}
  def validate(%Ping{} = msg, session_eid) do
    with :ok <- validate_id(msg.id),
         :ok <- validate_identity(msg.from, "from"),
         :ok <- validate_type(msg.type),
         :ok <- validate_timestamp(msg.timestamp),
         :ok <- validate_eid_match(msg.from, session_eid) do
      :ok
    end
  end

  # ---------------- UUID ----------------
  defp validate_id(id) when is_binary(id) and byte_size(id) > 0 do
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
    if is_binary(ident.eid) and byte_size(ident.eid) > 0 do
      :ok
    else
      error(@status_bad_request, "#{field}.eid must be non-empty", "#{field}.eid")
    end
  end

  defp validate_identity(_, field),
    do: error(@status_bad_request, "Malformed #{field} identity", field)

  # ---------------- Type ----------------
  defp validate_type(type) when type in @allowed_types do
    if type == @expected_type do
      :ok
    else
      error(
        @status_bad_request,
        "Only type=#{@expected_type} allowed at ingress",
        "type"
      )
    end
  end

  defp validate_type(_),
    do: error(@status_bad_request, "type must be 1 or 2", "type")

  # ---------------- Replay Window ----------------
  defp validate_timestamp(timestamp) when is_integer(timestamp) do
    now = System.system_time(:millisecond)

    cond do
      timestamp <= 0 ->
        error(@status_bad_request, "timestamp must be positive int64", "timestamp")

      abs(now - timestamp) > @replay_window_ms ->
        error(@status_out_of_order, "timestamp outside allowed replay window", "timestamp")

      true ->
        :ok
    end
  end

  defp validate_timestamp(_),
    do: error(@status_bad_request, "timestamp must be int64", "timestamp")

  # ---------------- Session Binding ----------------
  defp validate_eid_match(%Identity{eid: eid}, session_eid)
       when eid == session_eid,
       do: :ok

  defp validate_eid_match(_, _),
    do:
      error(
        @status_unauthorized,
        "EID mismatch — unauthorized sender",
        "from.eid"
      )

  # ---------------- Error Helper ----------------
  defp error(code, description, field),
    do: {:error, %{code: code, description: description, field: field}}
end
