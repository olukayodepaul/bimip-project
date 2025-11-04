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

  alias Bimip.{Message, MessageScheme, Identity}

  @route 6

  # ------------------------------------------------------------------------
  # SUCCESS / NORMAL MESSAGE
  # ------------------------------------------------------------------------
  def success(
        from_eid,
        from_device_id,
        to_eid \\ "",
        to_device_id \\ "",
        type \\ 1,
        payload \\ %{},
        encryption_type \\ "none",
        encrypted \\ "",
        signature \\ "",
        status \\ 4,
        id \\ "",
        signal_offset \\ "",
        user_offset \\ ""
      ) do
    message = %Message{
      id: id,
      signal_offset: signal_offset,
      user_offset: user_offset,
      from: %Identity{eid: from_eid, connection_resource_id: from_device_id},
      to: %Identity{eid: to_eid, connection_resource_id: to_device_id},
      type: type,
      timestamp: System.system_time(:millisecond),
      payload: Jason.encode!(payload),
      encryption_type: encryption_type,
      encrypted: encrypted,
      signature: signature,
      status: status
    }

    %MessageScheme{
      route: @route,
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
      to: %Identity{eid: to_eid, connection_resource_id: to_device_id},
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
