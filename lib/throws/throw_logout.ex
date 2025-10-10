defmodule ThrowLogouResponseSchema do
  @doc """
  Builds a Logout protobuf stanza for response or error.
  type: 2=RESPONSE, 3=ERROR
  status: 1=DISCONNECT, 2=FAIL, 3=SUCCESS, 4=PENDING
  """
  def logout(eid, device_id, type \\ 2, status \\ 1, details \\ nil) do
    logout = %Bimip.Logout{
      to: %Bimip.Identity{
        eid: eid,
        connection_resource_id: device_id
      },
      type: type,
      status: status,
      timestamp: System.system_time(:millisecond),
      details: details
    }

    %Bimip.MessageScheme{
      route: 14,
      payload: {:logout, logout}
    }
    |> Bimip.MessageScheme.encode()
  end
end
