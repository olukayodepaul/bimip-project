defmodule Chat.PrcMessage do

  def prc_message({%Bimip.Message{} = message, device_id, eid}) do
    %Chat.MessageStruct{
      message_id: message.message_id,
      from: %Chat.EntityStruct{
        eid: eid,
        connection_resource_id: device_id
      },
      to: %Chat.EntityStruct{
        eid: message.to.eid
      },
      timestamp: message.timestamp,
      payload: message.payload,
      encryption_type: message.encryption_type,
      encrypted: message.encrypted,
      signature: message.signature,
      device_id: device_id,
      eid: eid
    }
  end
end
