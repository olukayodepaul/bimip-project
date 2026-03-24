defmodule Bimip.Validators.FlowValidator do
  @moduledoc """
  Production-grade validation for Flow protobuf (One-to-Many).

  Enforces:
  - Rate limiting using @flow_rate_limit (monotonic time)
  - Identity integrity (sender verification)
  - EID spoof protection
  - Valid binary payload presence
  - Valid client timestamp
  """

  alias Bimip.Flow
  alias Bimip.Identity

  # ---------------- Status Codes ----------------
  @status_bad_request 400
  @status_too_many_requests 429

  # ---------------- Protocol Constraints ----------------
  @flow_rate_limit 5000  # Default 5s interval

  # ---------------- Public API ----------------
  @spec validate(Flow.t(), String.t(), integer(), integer() | nil) :: :ok | {:error, map()}
  def validate(%Flow{} = msg, authenticated_eid, last_flow_sent_at, min_interval \\ Application.Config.flow_rate_limit()) do
    with :ok <- validate_rate_limit(last_flow_sent_at, min_interval),
         :ok <- validate_identity(msg.from, "from"),
         :ok <- validate_eid_match(msg.from, authenticated_eid),
         :ok <- validate_id(msg.id),
         :ok <- validate_category(msg.category),
         :ok <- validate_payload(msg.payload),
         :ok <- validate_timestamp(msg.timestamp) do
      :ok
    end
  end

  # ---------------- Rate Limiting ----------------
  defp validate_rate_limit(last_sent_at, min_interval) do
    now = System.monotonic_time(:millisecond)
    elapsed = now - last_sent_at

  #   IO.puts("""
  # --- RATE LIMIT CHECK ---
  # Now: #{now}
  # Last: #{last_sent_at}
  # Elapsed: #{elapsed}ms
  # Required: #{min_interval}ms
  # ------------------------
  # """)

    if elapsed >= min_interval do
      :ok
    else
      # Calculate the "Wait" time
      remaining_ms = min_interval - elapsed

      # Round to 1 decimal place (e.g., 4.2s)
      wait_sec = Float.round(remaining_ms / 1000, 1)

      error(
        @status_too_many_requests,
        "Rate limit exceeded. Please wait #{wait_sec}s before the next flow broadcast.",
        "rate_limit"
      )
    end
  end

  # ---------------- Identity ----------------
  defp validate_identity(%Identity{eid: eid}, field) when is_binary(eid) and byte_size(eid) > 0,
    do: :ok

  defp validate_identity(_, field),
    do: error(@status_bad_request, "Malformed #{field} identity", field)

  # ---------------- EID Spoof Protection ----------------
  defp validate_eid_match(%Identity{eid: eid}, authenticated_eid) when eid == authenticated_eid,
    do: :ok

  defp validate_eid_match(_, _),
    do: error(@status_bad_request, "from.eid does not match authenticated authority", "from.eid")

  # ---------------- Flow Fields ----------------
  defp validate_id(id) when is_binary(id) and byte_size(id) > 0, do: :ok
  defp validate_id(_), do: error(@status_bad_request, "id must be non-empty string", "id")

  defp validate_category(cat) when is_binary(cat) and byte_size(cat) > 0, do: :ok
  defp validate_category(_), do: error(@status_bad_request, "category must be non-empty", "category")

  # ---------------- Payload ----------------
  defp validate_payload(payload) when is_binary(payload), do: :ok
  defp validate_payload(_), do: error(@status_bad_request, "payload must be bytes", "payload")

  # ---------------- Timestamp ----------------
  defp validate_timestamp(timestamp) when is_integer(timestamp) and timestamp > 0, do: :ok
  defp validate_timestamp(_),
    do: error(@status_bad_request, "timestamp must be positive int64 (Unix ms)", "timestamp")

  # ---------------- Error Helper ----------------
  defp error(code, description, field),
    do: {:error, %{code: code, description: description, field: field}}
end
