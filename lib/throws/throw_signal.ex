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
        from_eid,
        from_device_id,
        to_eid \\ "",
        to_device_id \\ "",
        status \\ 1,
        signal_offset \\ 0,
        user_offset \\ 0,
        id \\ "",
        error \\ ""
      ) do
    signal = %Bimip.Signal{
      id: id,
      signal_offset: "#{signal_offset}",
      user_offset: "#{user_offset}",
      status: status,
      timestamp: System.system_time(:millisecond),
      from: %Bimip.Identity{eid: from_eid, connection_resource_id: from_device_id},
      to: %Bimip.Identity{eid: to_eid, connection_resource_id: to_device_id},
      type: @type_response,
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
