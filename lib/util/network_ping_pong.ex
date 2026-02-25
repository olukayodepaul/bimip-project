defmodule Util.Network.AdaptivePingPong do
  @moduledoc """
  Adaptive native WebSocket heartbeat logic for a single-device GenServer.
  """

  require Logger
  alias Settings.AdaptiveNetwork
  alias Route.Connect

  @max_pong_counter AdaptiveNetwork.max_pong_retries()
  @default_ping_interval AdaptiveNetwork.default_ping_interval_ms()
  @max_allowed_delay AdaptiveNetwork.max_allowed_delay_seconds()

  # -------------------------
  # Core Adaptive Heartbeat
  # -------------------------
  def handle_ping(state) do
    now = DateTime.utc_now()
    interval_ms = maybe_adaptive_interval(state.last_rtt)

    # Silence Check: How long since the client last sent us ANY data?
    ms_since_seen = if state.last_seen, do: DateTime.diff(now, state.last_seen, :millisecond), else: :infinity

    cond do
      # SKIP: Client is talking to us. Skip the native ping to save bandwidth.
      ms_since_seen < interval_ms ->
        Logger.debug("[Heartbeat] Client active #{ms_since_seen}ms ago; skipping ping", device_id: state.device_id)
        schedule_ping(state.device_id, state.last_rtt)
        {:noreply, state}

      # ZOMBIE: It's been way too long since any successful interaction (dead socket).
      DateTime.diff(now, state.timer) > @max_allowed_delay ->
        Logger.error("[Heartbeat] Connection zombie (no response for #{DateTime.diff(now, state.timer)}s). Terminating.", device_id: state.device_id)
        Connect.send_terminate_signal_to_server({state.device_id, state.eid})
        {:stop, :normal, state}

      # PING: Send the native WebSocket frame (0x9)
      true ->
        Logger.info("[Heartbeat] Sending native ping; missed_pongs: #{state.missed_pongs + 1}", device_id: state.device_id)
        send(state.ws_pid, :send_ping) # Triggers {:reply, :ping, state}
        schedule_ping(state.device_id, state.last_rtt)
        {:noreply, %{state | timer: now, missed_pongs: state.missed_pongs + 1}}
    end
  end

  # -------------------------
  # Activity Tracking (Call this on every Message or Pong)
  # -------------------------
  def mark_active(state) do
    # Logged at debug level to avoid noise in production info logs
    Logger.debug("[Heartbeat] Activity detected; resetting counters", device_id: state.device_id)

    state
    |> Map.put(:last_seen, DateTime.utc_now())
    |> Map.put(:missed_pongs, 0)
    |> maybe_report_presence()
  end

  defp maybe_report_presence(state) do
    now = DateTime.utc_now()
    interval = Map.get(state, :presence_report_interval, 60_000)

    if is_nil(state.last_reported_seen) or DateTime.diff(now, state.last_reported_seen, :millisecond) >= interval do
      Logger.info("[Presence] Reporting active status to external service", device_id: state.device_id, uupid: state.uupid)
      %{state | last_reported_seen: now}
    else
      state
    end
  end

  # -------------------------
  # Native Pong Received
  # -------------------------
  def pongs_received(device_id, receive_time, state) do
    rtt = if state.timer, do: DateTime.diff(receive_time, state.timer, :millisecond), else: 0

    Logger.info("[Heartbeat] Native pong received (RTT: #{rtt}ms)", device_id: device_id)

    new_state = state
                |> Map.put(:last_rtt, rtt)
                |> Map.put(:max_missed_pongs_adaptive, maybe_adaptive_max_missed(rtt))
                |> mark_active()

    handle_status_refresh(new_state)
  end

  # -------------------------
  # Status & Global Presence
  # -------------------------
  defp handle_status_refresh(state) do
    if state.pong_counter + 1 >= @max_pong_counter do
      Logger.info("[Presence] Master server refresh (ONLINE)", device_id: state.device_id)
      Connect.send_pong_to_bimip_server_master(state.device_id, state.eid, "ONLINE")

      # Reset the counter after notifying Master
      {:noreply, %{state | pong_counter: 0, last_state_change: DateTime.utc_now()}}
    else
      # Just increment locally, don't talk to Master yet
      {:noreply, %{state | pong_counter: state.pong_counter + 1}}
    end
  end

  # -------------------------
  # Adaptive Calculations
  # -------------------------
  defp maybe_adaptive_interval(rtt) do
    if is_nil(rtt), do: @default_ping_interval, else: calculate_interval(rtt)
  end

  defp calculate_interval(rtt) do
    thresholds = AdaptiveNetwork.rtt_thresholds()
    intervals = AdaptiveNetwork.ping_intervals()
    cond do
      rtt > thresholds.high -> intervals.high_rtt
      rtt < thresholds.low -> intervals.default
      true -> intervals.medium_rtt
    end
  end

  defp maybe_adaptive_max_missed(rtt) do
    thresholds = AdaptiveNetwork.rtt_thresholds()
    max_m = AdaptiveNetwork.max_missed_pongs()
    cond do
      is_nil(rtt) -> max_m.default
      rtt > thresholds.high -> max_m.high
      rtt < thresholds.low -> max_m.low
      true -> max_m.default
    end
  end

  def schedule_ping(device_id, last_rtt \\ nil) do
    Connect.schedule_ping_registry(device_id, maybe_adaptive_interval(last_rtt))
  end
end
