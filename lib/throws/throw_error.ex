defmodule ThrowProtocolErrorSchema do

  @route_id 11

  def build(%{
    route_id: route_id,
    details: details,
    timestamp: timestamp
  }) do

    protocol_error = %Bimip.ProtocolError{
      route_id: route_id,
      details: details,
      timestamp: timestamp
    }

    %Bimip.MessageScheme{
      route_id: @route_id,
      payload: {:protocol_error, protocol_error}
    }
    |> Bimip.MessageScheme.encode()
  end
end
