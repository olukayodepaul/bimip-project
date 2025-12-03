defmodule Queue.Persist do
  @moduledoc """
  Builds a single-layer payload map for message persistence.
  The `payload` parameter in attrs is directly merged into the final map
  (no nested wrapping).
  """

  @transmission_mode 1


  def build(%{from: from, to: to, payload: payload} = _attrs, offset, peer_offset \\ nil) do

        per_user_offset = peer_offset || offset

        %Bimip.Message{
          message_id: payload.message_id,
          from: %Bimip.Identity{ eid: payload.from.eid, connection_resource_id: payload.from.connection_resource_id},
          to: %Bimip.Identity{ eid: payload.to.eid, connection_resource_id: payload.to.connection_resource_id},
          payload: payload.payload,
          encryption_type: payload.encryption_type,
          encrypted: payload.encrypted,
          signature: payload.signature,
          transmission_mode: @transmission_mode, # 1 Pusll request
          peer: %Bimip.Peer{ from: payload.from_peer, to: payload.to_peer, offset: offset, peer_offset: peer_offset }
        }
      end
end
