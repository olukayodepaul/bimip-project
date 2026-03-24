defmodule Queue.Persist do
  @moduledoc """
  Builds a single-layer payload map for message persistence.
  The `payload` parameter in attrs is directly merged into the final map
  (no nested wrapping).
  """

  @delivery_type 2

  def build(%Bimip.Message{} = payload, next_offset) do
    payload
    |> Map.put(:offset, next_offset)
  end

end
