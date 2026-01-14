defmodule Chat.Message.Model do

  def builder({%Bimip.Message{} = message, uupid, eid, device_id}) do
    %Chat.MessageStruct{
      peer_uid: message.peer_uid,
      from: %Chat.EntityStruct{
        eid: eid,
        connection_resource_id: device_id
      },
      to: %Chat.EntityStruct{
        eid: message.to.eid
      },
      timestamp: message.timestamp,
      payload: message.payload,
      payload_context: message.payload_context,
      encryption_type: message.encryption_type,
      encrypted: message.encrypted,
      signature: message.signature,
      device_id: device_id, #real device id
      uupid: uupid, # number
      eid: eid
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
