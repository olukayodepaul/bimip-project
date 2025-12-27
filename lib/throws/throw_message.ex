defmodule ThrowMessageSchema do

  alias Bimip.{Message, MessageScheme, Identity, Body, OWNERS}
  @route 6

    def build_bulk_message(message_list) when is_list(message_list) do

    body = %Body{
      route: 6,
      messages: message_list,
      timestamp: Until.UniPosTime.uni_pos_time()
    }

    %MessageScheme{
      route: 10,
      payload: {:body, body}
    }
    |> MessageScheme.encode()
  end

  # ------------------------------------------------------------------------
  # SUCCESS / NORMAL MESSAGE
  # ------------------------------------------------------------------------
  def build_message(
    %{
      peer_uid: peer_uid,
      offset: offset,
      timestamp: timestamp,
      type: type,
      signature: signature,
      to: %{eid: from_eid, connection_resource_id: from_device_id},
      from: %{eid: to_eid, connection_resource_id: to_device_id},
      payload: payload,
      payload_context: payload_context,
      encryption_type: encryption_type,
      encrypted: encrypted,
      transmission_mode: transmission_mode,
      reply_to: reply_to
    }) do

    message =  %Bimip.Message {
        peer_uid: peer_uid,
        from: %Bimip.Identity{eid: from_eid, connection_resource_id: from_device_id},
        to: %Bimip.Identity{eid: to_eid, connection_resource_id: to_device_id},
        timestamp: timestamp,
        payload: payload,
        payload_context: payload_context,
        encryption_type: encryption_type,
        encrypted: encrypted,
        signature: signature,
        type: type,
        transmission_mode: transmission_mode,
        reply_to: reply_to,
        offset: offset
      }

    %Bimip.MessageScheme{
      route: 6,
      payload: {:message, message}
    }
    |> Bimip.MessageScheme.encode()
  end


  # ------------------------------------------------------------------------
  # ERROR MESSAGE
  # ------------------------------------------------------------------------
  def error(
        id,
        from_eid,
        from_device_id,
        description,
        to_eid \\ "",
        to_device_id \\ ""
      ) do
    message = %Message{
      peer_uid: id,
      from: %Identity{eid: from_eid, connection_resource_id: from_device_id},
      timestamp: Until.UniPosTime.uni_pos_time(),
      payload: Jason.encode!(%{error: description}),
      encryption_type: "none",
      encrypted: "",
      signature: "",
    }

    %MessageScheme{
      route: @route,
      payload: {:message, message}
    }
    |> MessageScheme.encode()
  end
end
