defmodule Settings.Queue do
    #settings
    @moduledoc """
    Provides access to connection settings for Bimip.
    """

    @config :bimip

    def max_queue_size, do: get(:queue) |> Keyword.get(:max_queue_size, 1000)

    

    defp get(key), do: Application.get_env(@config, key, [])
end
