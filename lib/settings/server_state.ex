defmodule Settings.ServerState do
  @moduledoc """
  Provides access to device state thresholds for Bimip.
  """

  @config :bimip

  def stale_threshold_seconds,
    do: get(:server_state) |> Keyword.get(:stale_threshold_seconds, 180)

  def force_change_seconds,
    do: get(:server_state) |> Keyword.get(:force_change_seconds, 120)

  defp get(key), do: Application.get_env(@config, key, [])
end
