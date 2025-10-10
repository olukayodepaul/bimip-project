defmodule ThrowAwarenessSchema do
  @moduledoc """
  Builds Awareness stanzas for both success and error.

  Awareness responses respect location_sharing:
    - 1 = ENABLED → include latitude/longitude
    - 2 = DISABLED → latitude/longitude forced to 0.0
  """

  @route 2
  @type_response 2
  @type_error 3

  # ------------------------------------------------------------------------
  # SUCCESS / NORMAL STANZAS
  # ------------------------------------------------------------------------
  def success(from_eid, from_device_id, to_eid, to_device_id, status, location_sharing, latitude, longitude, ttl, details \\ "") do
    # Override latitude/longitude if sharing is disabled
    latitudes = if location_sharing == 1, do: latitude, else: 0.0
    longitudes = if location_sharing == 1, do: longitude, else: 0.0

    awareness = %Bimip.Awareness{
      from: %Bimip.Identity{eid: from_eid, connection_resource_id: from_device_id},
      to: %Bimip.Identity{eid: to_eid, connection_resource_id: to_device_id},
      type: @type_response,
      status: status,
      location_sharing: location_sharing,
      latitude: latitudes,
      longitude: longitudes,
      ttl: ttl,
      details: details,
      timestamp: System.system_time(:millisecond)
    }

    %Bimip.MessageScheme{
      route: @route,
      payload: {:awareness, awareness}
    }
    |> Bimip.MessageScheme.encode()
  end

  # ------------------------------------------------------------------------
  # ERROR STANZA
  # ------------------------------------------------------------------------
  def error(eid, device_id, description) do
    awareness = %Bimip.Awareness{
      from: %Bimip.Identity{eid: eid, connection_resource_id: device_id},
      to: %Bimip.Identity{eid: eid, connection_resource_id: device_id},
      type: @type_error,
      status: 0,
      location_sharing: 2,
      latitude: 0.0,
      longitude: 0.0,
      ttl: 0,
      details: description,
      timestamp: System.system_time(:millisecond)
    }

    %Bimip.MessageScheme{
      route: @route,
      payload: {:awareness, awareness}
    }
    |> Bimip.MessageScheme.encode()
  end
end
