defmodule Bimip.Validators.ComposeValidator do
  @moduledoc """
  Silent validation for Compose protobuf.

  Invalid compose events are dropped silently.
  Ensures:
  - `from` and `to` identities are valid
  - `from` is not equal to `to`
  - `type` is 1 (COMPOSING), 2 (RECORDING), or 3 (PAUSED)
  - `timestamp` is positive int64
  - `eid` matches `msg.from.eid`
  """

  alias Bimip.Compose
  alias Bimip.Identity

  @allowed_types [1, 2, 3]

  @spec validate(Compose.t(), String.t()) :: :ok | :drop
  def validate(%Compose{} = msg, eid) when is_binary(eid) do
    with :ok <- validate_identity(msg.from),
         :ok <- validate_identity(msg.to),
         :ok <- validate_from_to_not_same(msg.from, msg.to),
         :ok <- validate_type(msg.type),
         :ok <- validate_timestamp(msg.timestamp),
         :ok <- validate_sender_eid(msg.from, eid) do
      :ok
    else
      _ -> :drop
    end
  end

  # ---------------- Identity ----------------
  defp validate_identity(%Identity{eid: eid}) when is_binary(eid) and byte_size(eid) > 0,
    do: :ok

  defp validate_identity(_), do: :error

  # ---------------- from != to ----------------
  defp validate_from_to_not_same(%Identity{eid: eid}, %Identity{eid: eid}), do: :error
  defp validate_from_to_not_same(_, _), do: :ok

  # ---------------- Type ----------------
  defp validate_type(type) when type in @allowed_types, do: :ok
  defp validate_type(_), do: :error

  # ---------------- Timestamp ----------------
  defp validate_timestamp(ts) when is_integer(ts) and ts > 0, do: :ok
  defp validate_timestamp(_), do: :error

  # ---------------- Sender EID Check ----------------
  defp validate_sender_eid(%Identity{eid: from_eid}, eid) when from_eid == eid, do: :ok
  defp validate_sender_eid(_, _), do: :error
end
