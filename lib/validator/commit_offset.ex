defmodule Bimip.Validators.OffsetCommitValidator do
  @moduledoc """
  Production-grade validation for OffsetCommit protobuf.

  Enforces:
  - Authority identity integrity
  - Strict COMMIT type (1 only)
  - EID spoof protection
  - Offset integrity
  - Valid server timestamp
  """

  alias Bimip.OffsetCommit
  alias Bimip.Identity

  # ---------------- Status Codes ----------------
  @status_bad_request 400

  # ---------------- Protocol Constraints ----------------
  @commit_type 1
  @clock_window_ms 60_000

  # ---------------- Public API ----------------
  @spec validate(OffsetCommit.t(), String.t()) :: :ok | {:error, map()}
  def validate(%OffsetCommit{} = msg, authenticated_eid) do
    with :ok <- validate_identity(msg.from, "from"),
         :ok <- validate_eid_match(msg.from, authenticated_eid),
         :ok <- validate_commit_type(msg.type),
         :ok <- validate_offset(msg.offset),
         :ok <- validate_timestamp(msg.timestamp) do
      :ok
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

  # ---------------- Strict COMMIT Type ----------------
  defp validate_commit_type(@commit_type), do: :ok

  defp validate_commit_type(_),
    do: error(@status_bad_request, "type must be 1 (COMMIT)", "type")

  # ---------------- Offset ----------------
  defp validate_offset(offset) when is_integer(offset) and offset >= 0, do: :ok

  defp validate_offset(_),
    do: error(@status_bad_request, "offset must be non-negative int64", "offset")

  # ---------------- Timestamp ----------------
  defp validate_timestamp(timestamp) when is_integer(timestamp) and timestamp > 0 do
    now = System.system_time(:millisecond)
    diff = abs(now - timestamp)

    if diff <= @clock_window_ms do
      :ok
    else
      IO.inspect("Validation Failed: Diff is #{diff}ms. Server: #{now}, Client: #{timestamp}")
      error(@status_bad_request, "Timestamp clock skew too high (Unix ms)", "timestamp")
    end
  end

  defp validate_timestamp(_),
    do: error(@status_bad_request, "timestamp must be positive int64 (Unix ms)", "timestamp")

  # ---------------- Error Helper ----------------
  defp error(code, description, field),
    do: {:error, %{code: code, description: description, field: field}}
end
