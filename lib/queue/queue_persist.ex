defmodule Queue.Persist do
  @moduledoc """
  Builds a single-layer payload map for message persistence.
  The `payload` parameter in attrs is directly merged into the final map
  (no nested wrapping).
  """

  @transmission_mode 1
  @sender 1
  @receiver 3


  def build(%{ payload: payload} = _attrs, next_offset, sender_offset) do

        {peer_offset, type, to_peer } = if sender_offset == nil do {next_offset, @sender, payload.to.eid} else {sender_offset, @receiver, payload.from.eid} end

        IO.inspect(%Bimip.Message{
          offset: next_offset,
          type: type,
          message_id: payload.message_id,
          from: %Bimip.Identity{ eid: payload.from.eid, connection_resource_id: payload.from.connection_resource_id},
          to: %Bimip.Identity{ eid: payload.to.eid, connection_resource_id: payload.to.connection_resource_id},
          payload: payload.payload,
          encryption_type: payload.encryption_type,
          encrypted: payload.encrypted,
          signature: payload.signature,
          transmission_mode: @transmission_mode, # 1 Pull request
          peer: %Bimip.Peer{to: to_peer, peer_offset:  peer_offset}
        })

      end
end
