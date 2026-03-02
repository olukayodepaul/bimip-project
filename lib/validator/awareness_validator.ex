defmodule Bimip.Validators.AwarenessValidator do
  alias Bimip.Awareness

  @allowed_presence 1..5
  @allowed_broadcast [1, 2]
  @clock_window_ms 60_000
  # Safety cap for 64-bit integer to prevent memory/logic overflow
  @max_offset 1_000_000_000

  @spec validate(Awareness.t(), String.t()) :: :ok | {:error, map()}
  def validate(%Awareness{} = msg, actual_eid) do
    with :ok <- validate_identity(msg.from, actual_eid),
        :ok <- validate_presence(msg.presence),
        :ok <- validate_offset(msg.offset),
        :ok <- validate_broadcast(msg.broadcast) do
        # :ok <- validate_timestamp(msg.timestamp) do
      :ok
    end
  end

  # Identity: Since msg.from is an 'Identity' message in your Proto
  defp validate_identity(%{eid: provided_eid}, actual_eid) do
    if provided_eid == actual_eid, do: :ok, else: {:error, error_detail(101, "EID mismatch", "from.eid")}
  end
  defp validate_identity(_, _), do: {:error, error_detail(100, "Missing identity", "from")}

  # Presence: Must be within defined enum range
  defp validate_presence(p) when p in @allowed_presence, do: :ok
  defp validate_presence(_), do: {:error, error_detail(100, "Invalid presence", "presence")}

  # Offset: Must be a non-negative number and under a safety cap
  defp validate_offset(o) when is_integer(o) and o >= 0 and o <= @max_offset, do: :ok
  defp validate_offset(o) when is_integer(o), do: {:error, error_detail(100, "Offset out of bounds", "offset")}
  defp validate_offset(_), do: {:error, error_detail(100, "Offset must be a number", "offset")}

  # Broadcast: Protobuf int32 acting as a boolean (0 or 1)
  defp validate_broadcast(b) when b in @allowed_broadcast, do: :ok
  defp validate_broadcast(_), do: {:error, error_detail(100, "Broadcast must be 1 or 2", "broadcast")}

  # Timestamp: Positive integer with clock-skew protection
  defp validate_timestamp(ts) when is_integer(ts) do
    now = System.system_time(:millisecond)
    if abs(now - ts) < @clock_window_ms, do: :ok, else: {:error, error_detail(102, "Clock skew too high", "timestamp")}
  end
  defp validate_timestamp(_), do: {:error, error_detail(100, "Invalid timestamp", "timestamp")}

  defp error_detail(code, desc, field), do: %{code: code, description: desc, field: field}
end
