defmodule Queue.Persist do
  @moduledoc """
  Builds a single-layer payload map for message persistence.
  The `payload` parameter in attrs is directly merged into the final map
  (no nested wrapping).
  """

  @spec build(map(), integer(), integer() | nil) :: map()
  def build(%{from: from, to: to, payload: payload} = _attrs, signal_offset, user_offset \\ nil) do

    per_user_offset = user_offset || signal_offset

    %Bimip.Message{
      id: payload.id,
      signal_offset: signal_offset,
      user_offset: per_user_offset,
      from: %Bimip.Identity{ eid: payload.from.eid, connection_resource_id: payload.from.connection_resource_id},
      to: %Bimip.Identity{ eid: payload.to.eid, connection_resource_id: payload.to.connection_resource_id},
      payload: payload.payload,
      encryption_type: payload.encryption_type,
      encrypted: payload.encrypted,
      signature: payload.signature,
      signal_direction: 1, # Pusll request
      owners: %Bimip.OWNERS{ from: payload.from.eid, to: payload.to.eid},
    }

  end
end
