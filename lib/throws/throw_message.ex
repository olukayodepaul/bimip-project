defmodule ThrowMessageSchema do
  @moduledoc """
  Builds Message stanzas for both success and error.

  Status codes:
    - 1 = DELIVERED
    - 2 = READ
    - 3 = FORWARDED
    - 4 = SENT
    - 5 = PLAYED/VIEWED
    - 6 = TYPING
    - 7 = RECORDING
    - 8 = PAUSED
    - 9 = CANCELLED
  """

  alias Bimip.{Message, MessageScheme, Identity, Body}

  @route 6

  # ------------------------------------------------------------------------
  # BUILD INDIVIDUAL MESSAGE STRUCT
  # ------------------------------------------------------------------------
  def build_message(%{
      id: id,
      status: status,
      type: type,
      from: %{eid: from_eid, connection_resource_id: from_device_id},
      to: %{eid: to_eid, connection_resource_id: to_device_id},
      payload: payload,
      encryption_type: encryption_type,
      encrypted: encrypted,
      signature: signature,
      signal_offset: signal_offset,
      user_offset: user_offset
    }) do
  %Message{
    id: id,
    signal_offset: signal_offset,
    user_offset: user_offset,
    from: %Identity{eid: from_eid, connection_resource_id: from_device_id},
    to: %Identity{eid: to_eid, connection_resource_id: to_device_id},
    type: type,
    timestamp: System.system_time(:millisecond),
    payload:
      case payload do
        bin when is_binary(bin) -> bin
        map when is_map(map) -> Jason.encode!(map)
      end,
    encryption_type: encryption_type,
    encrypted: encrypted,
    signature: signature,
    status: status
  }
end


  # ------------------------------------------------------------------------
  # SUCCESS / NORMAL MESSAGE — WRAP ONLY
  # ------------------------------------------------------------------------
  def success(message_list) when is_list(message_list) do
    body = %Body{
      route: 6,
      message: message_list,
      timestamp: System.system_time(:millisecond)
    }

      %MessageScheme{
        route: 10,
        payload: {:body, body}
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
      type: 3, # error type
      timestamp: System.system_time(:millisecond),
      payload: Jason.encode!(%{error: description}),
      encryption_type: "none",
      encrypted: "",
      signature: "",
      status: 3
    }

    %MessageScheme{
      route: @route,
      payload: {:message, message}
    }
    |> MessageScheme.encode()
  end
end
