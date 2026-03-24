defmodule Bimip.Validators.AwarenessValidator do
  alias Bimip.Awareness

  @allowed_presence 1..5
  @allowed_broadcast [1, 2]
  # 60 seconds tolerance for drift/latency
  @clock_window_ms 60_000
  @max_offset 1_000_000_000

  @spec validate(Awareness.t(), String.t()) :: :ok | {:error, map()}
  def validate(%Awareness{} = msg, actual_eid) do
    with :ok <- validate_identity(msg.from, actual_eid),
         :ok <- validate_presence(msg.presence),
         :ok <- validate_offset(msg.offset),
         :ok <- validate_broadcast(msg.broadcast),
         :ok <- validate_timestamp(msg.timestamp) do # <--- Enabled
      :ok
    end
  end

  # Identity: Matches provided EID against session EID
  defp validate_identity(%{eid: provided_eid}, actual_eid) do
    if provided_eid == actual_eid, do: :ok, else: {:error, error_detail(101, "EID mismatch", "from.eid")}
  end
  defp validate_identity(_, _), do: {:error, error_detail(100, "Missing identity", "from")}

  # Presence/Offset/Broadcast checks...
  defp validate_presence(p) when p in @allowed_presence, do: :ok
  defp validate_presence(_), do: {:error, error_detail(100, "Invalid presence", "presence")}

  defp validate_offset(o) when is_integer(o) and o >= 0 and o <= @max_offset, do: :ok
  defp validate_offset(_), do: {:error, error_detail(100, "Invalid offset", "offset")}

  defp validate_broadcast(b) when b in @allowed_broadcast, do: :ok
  defp validate_broadcast(_), do: {:error, error_detail(100, "Broadcast must be 1 or 2", "broadcast")}

  # ---------------- Timestamp Validation (Unix/Epoch) ----------------
  defp validate_timestamp(ts) when is_integer(ts) and ts > 0 do
    # Get current server Unix/Epoch time in milliseconds
    now = System.system_time(:millisecond)

    # Calculate absolute difference to catch both "too old" and "too far future"
    if abs(now - ts) <= @clock_window_ms do
      :ok
    else
      error_msg = "Clock skew too high. Server: #{now}, Client: #{ts}"
      {:error, error_detail(102, error_msg, "timestamp")}
    end
  end

  defp validate_timestamp(_),
    do: {:error, error_detail(100, "Timestamp must be a positive Unix integer", "timestamp")}

  defp error_detail(code, desc, field), do: %{code: code, description: desc, field: field}
end
