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
      message_id: message_id,
      from: %{eid: from_eid, connection_resource_id: from_device_id},
      to: %{eid: to_eid, connection_resource_id: to_device_id},
      timestamp:  timestamp,
      payload: payload,
      encryption_type: encryption_type,
      encrypted: encrypted,
      signature: signature,
      type: type,
      transmission_mode: transmission_mode,
      peer: %{ from: from_peer, to: to_peer, offset: offset_peer, peer_offset: peer_offset }
      }) do

    message =  %Bimip.Message {
        message_id: message_id,
        from: %Bimip.Identity{eid: from_eid, connection_resource_id: from_device_id}, # the device_id of sender
        to: %Bimip.Identity{eid: to_eid, connection_resource_id: to_device_id},
        timestamp: timestamp,
        payload: payload,
        encryption_type: encryption_type,
        encrypted: encrypted,
        signature: signature,
        type: type,
        transmission_mode: transmission_mode,
        peer: %Bimip.Peer{ from: from_peer, to: to_peer, offset: offset_peer, peer_offset: peer_offset }
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
      message_id: id,
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
