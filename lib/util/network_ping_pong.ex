defmodule Util.Network.AdaptivePingPong do
  require Logger
  alias Settings.AdaptiveNetwork
  alias Route.Connect

  @max_silence_ms (AdaptiveNetwork.max_allowed_delay_seconds() || 60) * 1000
  @max_idle_ms 3 * 60 * 1000 # Testing: 1 minute
  @report_interval_ms 60_000

  # ==============================
  # PUBLIC API
  # ==============================

  def handle_ping(state) do
    now = now_ms()

    # 1. Gather all activity timestamps
    last_seen = state.last_seen
    last_user = Map.get(state, :last_user_activity) || last_seen
    last_ping_sent = Map.get(state, :last_ping_sent_at)

    # 2. Calculate durations
    ms_since_seen = silence_duration(now, last_seen)
    ms_since_user = silence_duration(now, last_user)
    ms_since_last_ping = silence_duration(now, last_ping_sent)

    # RELEVANT HEARTBEAT: The shortest time since we heard from the device (User OR Pong)
    ms_since_any_activity = Enum.min([ms_since_seen, ms_since_user])

    max_missed = adaptive_max_missed(state.last_rtt)
    interval = adaptive_interval(state.last_rtt)

    Logger.debug("[PingPong] Device: #{state.device_id} | Missed: #{state.missed_pongs} | AnyActivity: #{ms_since_any_activity}ms | UserIdle: #{ms_since_user}ms")

    cond do
      # PRIORITY 1: User Idle Logout (Human hasn't touched the app)
      ms_since_user > @max_idle_ms ->
        Logger.info("[PingPong] LOGOUT: User idle limit reached.", device_id: state.device_id)
        {:stop, :normal, state}

      # PRIORITY 2: Zombie connection (Absolute network silence)
      ms_since_seen > @max_silence_ms ->
        Logger.warning("[PingPong] TERMINATE: Zombie connection.", device_id: state.device_id)
        {:stop, :normal, state}

      # PRIORITY 3: Missed Pong Count
      state.missed_pongs >= max_missed ->
        Logger.error("[PingPong] TERMINATE: Missed #{state.missed_pongs} pongs.", device_id: state.device_id)
        {:stop, :normal, state}

      # PRIORITY 4: Send Ping Probe
      # Only send if NO user activity AND NO pongs have happened within the interval.
      ms_since_any_activity >= interval and ms_since_last_ping >= interval ->
        perform_ping_sequence(state, now)

      # PRIORITY 5: Healthy / User Active
      # If the user is sending data, we hit this branch and skip sending a Ping.
      true ->
        schedule_next_ping(state.device_id, state.last_rtt)
        {:noreply, state}
    end
  end

  @doc """
  CALL THIS when real user data is received.
  It resets both the idle timer and the network ping timer.
  """
  def mark_user_activity(state) do
    now = now_ms()
    state
    |> Map.put(:last_user_activity, now)
    |> Map.put(:last_seen, now)
    |> Map.put(:missed_pongs, 0)
    # ADD THIS: This prevents handle_federation_refresh from
    # sending a redundant ping right after a real user message.
    |> Map.put(:last_reported_ms, now)
  end

  def mark_active(state) do
    # Only resets network/missed pongs (used for automated pongs)
    state
    |> Map.put(:last_seen, now_ms())
    |> Map.put(:missed_pongs, 0)
  end

  def pongs_received(_device_id, _timestamp, state), do: pong_received(state)

  def pong_received(state) do
    now = now_ms()
    rtt = if Map.get(state, :last_ping_sent_at), do: now - state.last_ping_sent_at, else: 0

    # Pongs still trigger the refresh check, but because mark_user_activity
    # updated last_reported_ms, this will usually be skipped if activity is high.
    state
    |> Map.put(:last_rtt, rtt)
    |> mark_active()
    |> handle_federation_refresh()
  end

  # ==============================
  # INTERNAL HELPERS
  # ==============================

  defp perform_ping_sequence(state, now) do
    if Map.has_key?(state, :ws_pid) and Process.alive?(state.ws_pid) do
      send(state.ws_pid, :send_ping)
    end

    # Increment missed_pongs, but do NOT update last_seen yet.
    # Silence (ms_since_seen) will grow until the Pong actually returns.
    new_state = state
      |> Map.put(:last_ping_sent_at, now)
      |> Map.put(:missed_pongs, (state.missed_pongs || 0) + 1)

    Logger.debug("[PingPong] Action: Sending Ping. Missed Count: #{new_state.missed_pongs}")

    schedule_next_ping(new_state.device_id, new_state.last_rtt)
    {:noreply, new_state}
  end

  defp handle_federation_refresh(state) do
    now = now_ms()
    last_report = Map.get(state, :last_reported_ms, 0)

    # If the user sent a message 5 seconds ago, (now - last_report) will be 5000.
    # Since 5000 < 60000 (@report_interval_ms), this block is SKIPPED.
    if state.missed_pongs == 0 and (now - last_report) >= @report_interval_ms do
      Logger.debug("[PingPong] Periodic federation refresh for #{state.device_id}")
      server_inbound(state.device_id, :eid, :ping, state.eid)

      # Return the state with the new timestamp
      Map.put(state, :last_reported_ms, now)
    else
      state # Just return the state as is
    end
  end

  defp now_ms, do: System.monotonic_time(:millisecond)

  defp silence_duration(_now, nil), do: 9_999_999
  defp silence_duration(now, last_time), do: now - last_time

  defp adaptive_interval(nil), do: AdaptiveNetwork.default_ping_interval_ms()
  defp adaptive_interval(rtt) do
    thresholds = AdaptiveNetwork.rtt_thresholds()
    intervals = AdaptiveNetwork.ping_intervals()
    cond do
      rtt > thresholds.high -> intervals.high_rtt
      rtt < thresholds.low -> intervals.default
      true -> intervals.medium_rtt
    end
  end

  defp adaptive_max_missed(nil), do: AdaptiveNetwork.max_missed_pongs().default
  defp adaptive_max_missed(rtt) do
    thresholds = AdaptiveNetwork.rtt_thresholds()
    max_m = AdaptiveNetwork.max_missed_pongs()
    cond do
      rtt > thresholds.high -> max_m.high
      rtt < thresholds.low -> max_m.low
      true -> max_m.default
    end
  end

  def schedule_next_ping(device_id, rtt) do
    interval = adaptive_interval(rtt)
    jitter = :rand.uniform(150)
    Connect.schedule_ping_registry(device_id, interval + jitter)
  end

  defp server_inbound(payload, channel, signal_to_server, eid) do
    {channel, eid, signal_to_server, payload}
    |> Connect.client_server_inbound()
  end
end
