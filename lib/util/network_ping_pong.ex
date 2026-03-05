defmodule Util.Network.AdaptivePingPong do
  require Logger
  alias Settings.AdaptiveNetwork
  alias Route.Connect

  # Absolute network silence threshold (1 second)
  # NOTE: In production, consider 5000ms to avoid excessive log noise.
  @max_silence_ms 1000

  # Session lifetime (3 minutes) - Trigger for Hard Termination & Compaction
  @max_idle_ms 180_000

  # Federation/Report heartbeat (1 minute)
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

    # RELEVANT HEARTBEAT: Shortest time since we heard from the device (User OR Pong)
    ms_since_any_activity = Enum.min([ms_since_seen, ms_since_user])

    max_missed = adaptive_max_missed(state.last_rtt)
    interval = adaptive_interval(state.last_rtt)

    cond do
      # PRIORITY 1: User Idle Logout (The Hard Stop)
      ms_since_user > @max_idle_ms ->
        Logger.info("[PingPong] LOGOUT: User idle limit reached.", device_id: state.device_id)

        # 2026-03-04 Logic: Notify service to look into manifest,
        # remove list from positions, and delete device settings.
        server_inbound(state.device_id, :eid, :terminate, state.eid)

        # Kill the websocket process
        socket_terminate(state.ws_pid)

        {:stop, :normal, state}

      # PRIORITY 2: Network Issues (Zombie or Missed Pongs)
      # We check this before the standard interval to catch silent connections.
      ms_since_seen > @max_silence_ms or state.missed_pongs >= max_missed ->
        if state.missed_pongs > 2 do
          Logger.warning("[PingPong] LIMPING: #{state.device_id} missed #{state.missed_pongs} pongs.")
        end
        perform_ping_sequence(state, now)

      # PRIORITY 3: Standard Adaptive Ping Probe
      ms_since_any_activity >= interval and ms_since_last_ping >= interval ->
        perform_ping_sequence(state, now)

      # PRIORITY 4: Healthy / Active
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
    |> Map.put(:last_reported_ms, now)
  end

  def mark_active(state) do
    # Instead of jumping to 0, we move 1 step closer to healthy.
    # This makes the "Zombie" detection more persistent on bad networks.
    current_missed = Map.get(state, :missed_pongs, 0)
    new_missed = max(current_missed - 1, 0)

    Map.put(state, :missed_pongs, new_missed)
  end

  def pongs_received(_device_id, _timestamp, state), do: pong_received(state)

  def pong_received(state) do
    now = now_ms()
    rtt = if Map.get(state, :last_ping_sent_at), do: now - state.last_ping_sent_at, else: 0

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

    # Increment missed_pongs.
    # Silence (ms_since_seen) grows until mark_user_activity is called.
    new_state = state
      |> Map.put(:last_ping_sent_at, now)
      |> Map.put(:missed_pongs, (state.missed_pongs || 0) + 1)

    schedule_next_ping(new_state.device_id, new_state.last_rtt)

    # Return {:noreply, new_state} to ensure the GenServer saves the missed_pongs count.
    {:noreply, new_state}
  end

  defp handle_federation_refresh(state) do
    now = now_ms()
    last_report = Map.get(state, :last_reported_ms, 0)

    if state.missed_pongs == 0 and (now - last_report) >= @report_interval_ms do
      Map.put(state, :last_reported_ms, now)
    else
      state
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
    # Jitter prevents thundering herd on the server
    jitter = :rand.uniform(150)
    Connect.schedule_ping_registry(device_id, interval + jitter)
  end

  defp server_inbound(payload, channel, signal_to_server, eid) do
    {channel, eid, signal_to_server, payload}
    |> Connect.client_server_inbound()
  end

  defp socket_terminate(ws_pid) do
    if ws_pid && Process.alive?(ws_pid) do
      send(ws_pid, :terminate_socket)
    end
  end
end
