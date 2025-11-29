defmodule ThrowMessageSchema do

  alias Bimip.{Message, MessageScheme, Identity, Body}
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
      id: id,
      from: %{eid: from_eid, connection_resource_id: from_device_id},
      to: %{eid: to_eid, connection_resource_id: to_device_id},
      payload: payload,
      encryption_type: encryption_type,
      encrypted: encrypted,
      signature: signature,
      signal_type: signal_type,
      user_offset: user_offset,
      signal_offset: signal_offset,
      signal_direction: signal_direction,
      timestamp:  timestamp,
      owner: %{eid: owner_eid, connection_resource_id: owner_device_id},
      }) do

      # Normalize payload: encode map -> JSON, or use string directly
      payload_json =
        case payload do
          bin when is_binary(bin) -> bin
          map when is_map(map) -> Jason.encode!(map)
        end

    message =  %Message {
        id: id,
        signal_offset: signal_offset,
        user_offset: user_offset,
        from: %Identity{eid: from_eid, connection_resource_id: from_device_id}, # the device_id of sender
        to: %Identity{eid: to_eid, connection_resource_id: to_device_id},
        timestamp: timestamp,
        payload: payload_json,
        encryption_type: encryption_type,
        encrypted: encrypted,
        signature: signature,
        signal_type: signal_type,
        signal_direction: signal_direction,
        owner: %Identity{eid: owner_eid, connection_resource_id: owner_device_id},
      }

    %MessageScheme{
      route: 6,
      payload: {:message, message}
    }
    |> MessageScheme.encode()
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
      id: id,
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
