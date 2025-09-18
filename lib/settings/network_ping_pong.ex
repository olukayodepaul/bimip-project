defmodule Settings.AdaptiveNetwork do
  @moduledoc """
  Provides access to adaptive network ping/pong settings for Bimip.
  """

  @config :bimip
  @key :adaptive_network_ping_pong

  # Basic
  def default_ping_interval_ms, do: get(:default_ping_interval_ms, 10_000)
  def max_allowed_delay_seconds, do: get(:max_allowed_delay_seconds, 45)
  def max_pong_retries, do: get(:max_pong_retries, 3)
  def initial_max_missed_pings, do: get(:initial_max_missed_pings, 6)

  # Adaptive
  def rtt_thresholds, do: get(:rtt_thresholds, %{high: 500, low: 100})
  def ping_intervals, do: get(:ping_intervals, %{high_rtt: 20_000, medium_rtt: 15_000, default: 10_000})
  def max_missed_pongs, do: get(:max_missed_pongs, %{high: 8, low: 3, default: 5})

  defp get(setting, default),
    do: Application.get_env(@config, @key, []) |> Keyword.get(setting, default)
end
