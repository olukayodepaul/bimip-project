defmodule ThrowMessageSchema do
  alias Bimip.{Message, MessageScheme, Identity, Body}
  @route 6
  @bulk_route 10

  def build_bulk_message(message_list, timestamp) when is_list(message_list) do

    body = %Body{
      route_id: @route,
      messages: message_list,
      timestamp: timestamp
    }

    %MessageScheme{
      route_id: @bulk_route,
      payload: {:body, body}
    }
    |>MessageScheme.encode()

  end

  def build_message(%{
    id: id,
    from: from_eid,
    to: to_eid,
    offset: offset,
    timestamp: timestamp,
    payload: payload,
    delivery_type: delivery_type,
    participant_role: participant_role,
    content_type: content_type,
    ephemeral_public_key: ephemeral_public_key,
    mac: mac,
    message_type: message_type
  }) do

    message = %Message{
      id: id,
      from: %Identity{eid: from_eid},
      to: %Identity{eid: to_eid},
      offset: offset,
      timestamp: timestamp,
      payload: payload,
      delivery_type: delivery_type,
      participant_role: participant_role,
      content_type: content_type,
      ephemeral_public_key: ephemeral_public_key,
      mac: mac,
      message_type: message_type
    }

    %MessageScheme{
      route_id: @route,
      payload: {:message, message}
    }
    |>MessageScheme.encode()

  end
end
