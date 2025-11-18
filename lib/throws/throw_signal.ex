defmodule ThrowSignalSchema do
  @moduledoc """
  Builds Signal stanzas for both success and error.

  Signal stanzas are used by client and server to reconcile message status.
  """

  @route 7
  @type_response 2
  @type_error 3

  # ------------------------------------------------------------------------
  # SUCCESS / NORMAL STANZAS
  # ------------------------------------------------------------------------
  def success(
        from,
        to,
        status,
        signal_offset,
        user_offset,
        id,
        signal_offset_state \\ true,
        signal_type \\ 1,
        error \\ ""
      ) do
    signal = %Bimip.Signal{
      id: id,
      signal_offset: signal_offset,
      user_offset: user_offset,
      status: status,
      timestamp: System.system_time(:millisecond),
      from: %Bimip.Identity{eid: from.eid, connection_resource_id: from.connection_resource_id},
      to: %Bimip.Identity{eid: to.eid, connection_resource_id: to.connection_resource_id},
      type: @type_response,
      signal_type: signal_type,
      signal_offset_state: signal_offset_state,
      signal_ack_state: %Bimip.SignalAckState{send: true, received: false, read: false },
      error: error
    }

    %Bimip.MessageScheme{
      route: @route,
      payload: {:signal, signal}
    }
    |> Bimip.MessageScheme.encode()
  end

  # ------------------------------------------------------------------------
  # ERROR STANZA
  # ------------------------------------------------------------------------
  def error(eid, device_id, description) do
    signal = %Bimip.Signal{
      id: "",
      signal_offset: "",
      user_offset: "",
      status: 0,
      timestamp: System.system_time(:millisecond),
      from: %Bimip.Identity{eid: eid, connection_resource_id: device_id},
      to: %Bimip.Identity{eid: eid, connection_resource_id: device_id},
      type: @type_error,
      error: description
    }

    %Bimip.MessageScheme{
      route: @route,
      payload: {:signal, signal}
    }
    |> Bimip.MessageScheme.encode()
  end
end
