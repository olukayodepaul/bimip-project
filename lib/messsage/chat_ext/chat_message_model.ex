defmodule Chat.Message.Model do

  def builder({%Bimip.Message{} = message, device_id, uupid}) do
    %{
      message: message,
      device_id: device_id,
      uupid: uupid
    }
  end

  def to_message_struct(raw) do
    %Chat.MessageStruct{
      peer_uid: raw.peer_uid,
      timestamp: raw.timestamp,
      payload: raw.payload,
      payload_context: raw.payload_context,
      encryption_type: raw.encryption_type,
      encrypted: raw.encrypted,
      signature: raw.signature,

      # derived fields
      device_id: raw.from.connection_resource_id,
      eid: raw.from.eid,

      from: %Chat.EntityStruct{
        eid: raw.from.eid,
        connection_resource_id: raw.from.connection_resource_id
      },

      to: %Chat.EntityStruct{
        eid: raw.to.eid,
        connection_resource_id: raw.to.connection_resource_id
      }
    }
  end

end
