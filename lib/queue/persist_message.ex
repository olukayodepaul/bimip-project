defmodule PersistMessage do
  @moduledoc """
  Builds a single-layer payload map for message persistence.
  The `payload` parameter in attrs is directly merged into the final map
  (no nested wrapping).
  """

  @spec build(map(), integer(), integer() | nil) :: map()
  def build(%{from: from, to: to, payload: payload} = _attrs, signal_offset, user_offset \\ nil) do
    per_user_offset = user_offset || signal_offset

    # Merge the given payload with our added offsets and device id
    Map.merge(payload, %{
      device_id: from[:connection_resource_id],
      signal_offset: "#{signal_offset}",
      user_offset: "#{per_user_offset}",
      signal_type: 1
    })
  end
end
