defmodule Queue.Persist do
  @moduledoc """
  Builds a single-layer payload map for message persistence.
  The `payload` parameter in attrs is directly merged into the final map
  (no nested wrapping).
  """

  @delivery_type 2

  def build(%{payload: %Bimip.Message{} = payload}, next_offset, participant_role) do
    payload
    |> Map.put(:offset, next_offset)
    |> Map.put(:delivery_type, @delivery_type)
    |> Map.put(:participant_role, participant_role)
  end

end
