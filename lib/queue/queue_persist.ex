defmodule Queue.Persist do
  @moduledoc """
  Builds a single-layer payload map for message persistence.
  The `payload` parameter in attrs is directly merged into the final map
  (no nested wrapping).
  """

  @transmission_mode 1

  def build(%{ payload: payload} = _attrs, next_offset, reply_to, type, payload_context) do

      %Bimip.Message{
          offset: next_offset,
          type: type,
          peer_uid: payload.peer_uid,
          from: %Bimip.Identity{ eid: payload.from.eid, connection_resource_id: payload.from.connection_resource_id},
          to: %Bimip.Identity{ eid: payload.to.eid, connection_resource_id: payload.to.connection_resource_id},
          payload: payload.payload,
          payload_context: payload_context,
          encryption_type: payload.encryption_type,
          encrypted: payload.encrypted,
          signature: payload.signature,
          transmission_mode: @transmission_mode,
          reply_to: reply_to
        }

      end
end
