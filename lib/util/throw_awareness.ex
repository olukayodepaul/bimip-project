defmodule ThrowAwareness do
  @route 2

  def awareness(from, to, intention, status \\ 1, latitude \\ 0.0, longitude \\ 0.0, location_sharing \\ false) do
    awareness = %Bimip.Awareness{
      from: from,
      to: to,
      status: status,
      location_sharing: location_sharing,
      latitude: latitude,
      longitude: longitude,
      intention: intention,
      timestamp: System.system_time(:millisecond)
    }

    response = %Bimip.MessageScheme{
      route: @route,
      payload: {:awareness, awareness}
    }

    Bimip.MessageScheme.encode(response)
  end
end

