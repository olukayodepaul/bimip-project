defmodule ThrowErrorScheme do
  def error(code, details, route) do
    error = %Bimip.ErrorMessage{
      code: code,
      error_origin: route,
      details: details,
      timestamp: System.system_time(:millisecond)
    }

    response = %Bimip.MessageScheme{
      route: 11,
      payload: {:error, error}
    }

    Bimip.MessageScheme.encode(response)
  end
end