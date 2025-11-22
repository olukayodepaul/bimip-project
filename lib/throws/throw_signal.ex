defmodule ThrowSignalSchema do
  @moduledoc """
  Builds Signal stanzas for both success and error.

  Signal stanzas are used by client and server to reconcile message status.
  """

  @route 7
  @type_response 2
  @type_error 3

  alias Until.UniPosTime

  # ------------------------------------------------------------------------
  # SUCCESS / NORMAL STANZAS
  # ------------------------------------------------------------------------
  def success(
      %{
        id: id,
        signal_offset: signal_offset,
        user_offset: user_offset,
        status: status,
        from: from,
        to: to,
        signal_type: signal_type,
        signal_ack_state: %{send: send, delivered: delivered, read: read, advance_offset: advance_offset},
        signal_request: signal_request
      }) do
    signal = %Bimip.Signal{
      id: id,
      signal_offset: signal_offset,
      user_offset: user_offset,
      status: status,
      from: %Bimip.Identity{eid: from.eid, connection_resource_id: from.connection_resource_id},
      to: %Bimip.Identity{eid: to.eid, connection_resource_id: to.connection_resource_id},
      signal_type: signal_type,
      signal_ack_state: %Bimip.SignalAckState{send: send, delivered: delivered, read: read, advance_offset: advance_offset },
      signal_request: signal_request,
      type: @type_response,
      timestamp: UniPosTime.uni_pos_time(),
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
