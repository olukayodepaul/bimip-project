defmodule Chat.Message.Model do

  def builder({%Bimip.Message{} = message, device_id, eid, app_device_id}) do
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
      device_id: device_id,
      app_device_id: app_device_id,
      eid: eid
    }
  end

end
