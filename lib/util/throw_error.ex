defmodule ThrowErrorScheme do
  @moduledoc "Builds protobuf error messages for responses"

  def error(code, details, route) do
    encoded_details =
      cond do
        is_map(details) -> encode_details(details)
        is_binary(details) -> details
        true -> inspect(details)
      end

    error = %Bimip.ErrorMessage{
      code: code,
      error_origin: route,
      details: encoded_details,
      timestamp: System.system_time(:millisecond)
    }

    %Bimip.MessageScheme{
      route: 11,
      payload: {:error, error}
    }
    |> Bimip.MessageScheme.encode()
  end

  defp encode_details(%{description: desc, field: field}) do
    "Field '#{field}' → #{desc}"
  end

  defp encode_details(map) do
    Enum.map_join(map, ", ", fn {k, v} -> "#{k}=#{v}" end)
  end
end
