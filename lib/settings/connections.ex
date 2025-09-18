defmodule Settings.Connections do
    #settings
    @moduledoc """
    Provides access to connection settings for Bimip.
    """

    @config :bimip

    def cert_file, do: get(:connections) |> Keyword.get(:cert_file, "priv/cert.pem")
    def key_file, do: get(:connections) |> Keyword.get(:key_file, "priv/key.pem")
    def port, do: get(:connections) |> Keyword.get(:port, 4000)
    def secure_tls?, do: get(:connections) |> Keyword.get(:secure_tls, false)
    def resource_path, do: get(:connections) |> Keyword.get(:resource_path, "/")
    def idle_timeout, do: get(:connections) |> Keyword.get(:idle_timeout, 60000)

    

    defp get(key), do: Application.get_env(@config, key, [])
end
