defmodule Bimip.Validators.LocationStreamValidator do
  @moduledoc """
  Production-grade validation for LocationStream protobuf.

  Enforces:
  - Rate limiting (min 3s interval using monotonic time)
  - Identity integrity (from/to)
  - EID spoof protection
  - Coordinate range safety
  - Valid client timestamp
  """

  alias Bimip.LocationStream
  alias Bimip.Identity

  # ---------------- Status Codes ----------------
  @status_bad_request 400
  @status_too_many_requests 429

  # ---------------- Protocol Constraints ----------------
  @min_interval_ms 3000

  # ---------------- Public API ----------------
  @spec validate(LocationStream.t(), String.t(), integer()) :: :ok | {:error, map()}
  def validate(%LocationStream{} = msg, authenticated_eid, last_location_stream) do
    with :ok <- validate_rate_limit(last_location_stream),
         :ok <- validate_identity(msg.from, "from"),
         :ok <- validate_identity(msg.to, "to"),
         :ok <- validate_eid_match(msg.from, authenticated_eid),
         :ok <- validate_latitude(msg.latitude),
         :ok <- validate_longitude(msg.longitude),
         :ok <- validate_timestamp(msg.timestamp) do
      :ok
    end
  end

  # ---------------- Rate Limiting ----------------
  defp validate_rate_limit(last_sent_at) do
    now = System.monotonic_time(:millisecond)

    # If last_sent_at is 0, (now - 0) will be > 3000, allowing the first hit.
    if (now - last_sent_at) >= @min_interval_ms do
      :ok
    else
      error(@status_too_many_requests, "Location stream flood detected (min 3s)", "rate_limit")
    end
  end

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

  # ---------------- EID Spoof Protection ----------------
  defp validate_eid_match(%Identity{eid: eid}, authenticated_eid) when eid == authenticated_eid,
    do: :ok

  defp validate_eid_match(_, _),
    do: error(@status_bad_request, "from.eid does not match authenticated authority", "from.eid")

  # ---------------- Coordinates ----------------
  defp validate_latitude(lat) when is_number(lat) and lat >= -90.0 and lat <= 90.0, do: :ok
  defp validate_latitude(_),
    do: error(@status_bad_request, "latitude must be between -90 and 90", "latitude")

  defp validate_longitude(lon) when is_number(lon) and lon >= -180.0 and lon <= 180.0, do: :ok
  defp validate_longitude(_),
    do: error(@status_bad_request, "longitude must be between -180 and 180", "longitude")

  # ---------------- Timestamp ----------------
  defp validate_timestamp(timestamp) when is_integer(timestamp) and timestamp > 0, do: :ok
  defp validate_timestamp(_),
    do: error(@status_bad_request, "timestamp must be positive int64 (Unix ms)", "timestamp")

  # ---------------- Error Helper ----------------
  defp error(code, description, field),
    do: {:error, %{code: code, description: description, field: field}}
end
