defmodule Util.Network.AdaptivePingPong do
  @moduledoc """
  Handles network-level PingPong for child GenServers.

  Features:
    - Tracks missed pongs and RTT per device
    - Dynamically adjusts ping frequency and max missed pongs
    - Schedules next ping automatically
    - Integrates with DeviceStateChange to trigger online/offline state updates
    - Terminates after exceeding max allowed delay with no pong
  """

  require Logger
  alias Settings.AdaptiveNetwork
  alias App.RegistryHub
  alias Util.Client.DeviceState

  @max_pong_counter AdaptiveNetwork.max_pong_retries()
  @default_ping_interval AdaptiveNetwork.default_ping_interval_ms()
  @max_allowed_delay AdaptiveNetwork.max_allowed_delay_seconds()

  # -------------------------
  # Handle periodic ping
  # -------------------------
  def handle_ping(state) when is_map(state) do
    missed = Map.get(state, :missed_pongs, 0)
    counter = Map.get(state, :pong_counter, 0)
    last_ping = Map.get(state, :timer, DateTime.utc_now())
    eid = Map.get(state, :eid)
    device_id = Map.get(state, :device_id)
    ws_pid = Map.get(state, :ws_pid)
    last_rtt = Map.get(state, :last_rtt, nil)
    max_missed = Map.get(state, :max_missed_pongs_adaptive, AdaptiveNetwork.initial_max_missed_pings())
    now = DateTime.utc_now()
    delta = DateTime.diff(now, last_ping)
    last_state_change = Map.get(state, :last_state_change, DateTime.utc_now())

    cond do
      # Ping delayed → terminate
      delta > @max_allowed_delay ->
        Logger.error(
          "[#{device_id}] Ping delayed by #{delta}s (> #{@max_allowed_delay}), terminating GenServer"
        )
        RegistryHub.send_terminate_signal_to_server({device_id, eid})
        {:stop, :normal, state}

      # Too many missed pongs → mark offline
      missed >= max_missed ->
        Logger.error(
          "[#{device_id}] Device OFFLINE: missed #{missed} pings in a row (limit=#{max_missed})"
        )

        case state_change(device_id, eid, "OFFLINE", last_state_change, state) do
          {:chr, new_device_state} ->
            Logger.warning("[#{device_id}] OFFLINE state change emitted to RegistryHub")
            send(ws_pid, :send_ping)
            schedule_ping(device_id, last_rtt)

            {:noreply,
              %{
                state
                | missed_pongs: max_missed,
                  pong_counter: counter,
                  last_rtt: nil,
                  last_send_ping: nil,
                  last_state_change: now,
                  device_state: new_device_state
              }}

          {:unchr, same_device_state} ->
            Logger.debug("[#{device_id}] Still OFFLINE (no new state change)")
            send(ws_pid, :send_ping)
            schedule_ping(device_id, last_rtt)

            {:noreply,
              %{
                state
                | missed_pongs: max_missed,
                  pong_counter: counter,
                  last_rtt: nil,
                  last_send_ping: nil,
                  device_state: same_device_state
              }}
        end

      # Normal ping
      true ->
        Logger.info(
          "[#{device_id}] Sending ping (missed=#{missed}/#{max_missed}, " <>
            "remaining=#{max_missed - missed}, counter=#{counter})"
        )

        send(ws_pid, :send_ping)
        schedule_ping(device_id, last_rtt)
        handle_increment_counter(state, counter, missed, last_rtt, now, device_id, eid, last_state_change)
    end
  end

  # -------------------------
  # Increment pong counter
  # -------------------------
  defp handle_increment_counter(state, counter, missed, last_rtt, now, device_id, eid, last_state_change) do
    case increment_counter(counter, device_id, eid, last_state_change, state) do
      {:ok, counter, cur_new_state} ->
        update_state_after_increment(state, counter, missed, last_rtt, now, cur_new_state)

      {:er, counter} ->
        Logger.debug(
          "[#{device_id}] Missed pong incremented → #{missed + 1} (limit=#{Map.get(state, :max_missed_pongs_adaptive)})"
        )

        {:noreply,
          %{
            state
            | missed_pongs: missed + 1,
              pong_counter: counter,
              timer: now,
              last_rtt: last_rtt,
              last_send_ping: now
          }}
    end
  end

  defp update_state_after_increment(state, counter, missed, last_rtt, now, {:chr, chr_device_state}) do
    Logger.info("[#{state.device_id}] Device ONLINE state refreshed via ping counter reset")

    {:noreply,
      %{
        state
        | missed_pongs: missed + 1,
          pong_counter: counter,
          timer: now,
          last_rtt: last_rtt,
          last_send_ping: now,
          last_state_change: DateTime.utc_now(),
          device_state: chr_device_state
      }}
  end

  defp update_state_after_increment(state, counter, missed, last_rtt, now, {:unchr, unchr_device_state}) do
    Logger.debug("[#{state.device_id}] Device state unchanged (ONLINE) after ping counter increment")

    {:noreply,
    %{
      state
      | missed_pongs: missed + 1,
        pong_counter: counter,
        timer: now,
        last_rtt: last_rtt,
        last_send_ping: now,
        device_state: unchr_device_state
    }}
  end

  defp increment_counter(counter, device_id, eid, last_state_change, state) do
    if counter + 1 >= @max_pong_counter do
      Logger.debug("[#{device_id}] Ping counter limit reached → ONLINE transition for #{eid}")
      new_state = state_change(device_id, eid, "ONLINE", last_state_change, state)
      {:ok, 0, new_state}
    else
      {:er, counter + 1}
    end
  end

  # -------------------------
  # Device state change
  # -------------------------
  def state_change(device_id, eid, status, last_state_change, state, awareness_intention \\ 2) do
    
    attrs = %{
      status: status,
      last_seen: DateTime.utc_now(),
      awareness_intention: awareness_intention,
      last_activity: last_state_change
    }


    device_state = Map.get(state, :device_state)

    case DeviceState.track_state_change(attrs, device_state) do
      {:changed, prev_status, new_state} ->
        IO.inspect({"state change here is my 1", status})
        Logger.info("[#{device_id}] State changed #{prev_status} → #{status}")

      IO.inspect({"state change here is my 2", status, prev_status})
        RegistryHub.send_pong_to_bimip_server_master(device_id, eid, prev_status)

        {:chr, new_state}

      {:refresh, prev_status, new_state} ->
        Logger.debug("[#{device_id}] State refresh #{prev_status} → #{status}")
        RegistryHub.send_pong_to_bimip_server_master(device_id, eid, prev_status)
        {:chr, new_state}

      {:unchanged, prev_status, new_state} ->
        Logger.debug("[#{device_id}] State unchanged (#{prev_status})")
        {:unchr, new_state}
    end
  end

  # -------------------------
  # Adaptive ping interval
  # -------------------------
  defp calculate_adaptive_interval(rtt) when is_integer(rtt) do
    thresholds = AdaptiveNetwork.rtt_thresholds()
    intervals = AdaptiveNetwork.ping_intervals()

    cond do
      rtt > thresholds.high -> intervals.high_rtt
      rtt < thresholds.low -> intervals.default
      true -> intervals.medium_rtt
    end
  end

  defp maybe_adaptive_interval(nil), do: @default_ping_interval
  defp maybe_adaptive_interval(rtt) when is_integer(rtt), do: calculate_adaptive_interval(rtt)

  # -------------------------
  # Adaptive max missed pongs
  # -------------------------
  # defp maybe_adaptive_max_missed(nil), do: AdaptiveNetwork.max_missed_pongs().default
  defp maybe_adaptive_max_missed(rtt) when is_integer(rtt) do
    thresholds = AdaptiveNetwork.rtt_thresholds()
    max_missed = AdaptiveNetwork.max_missed_pongs()

    cond do
      rtt > thresholds.high -> max_missed.high
      rtt < thresholds.low -> max_missed.low
      true -> max_missed.default
    end
  end

  # -------------------------
  # Schedule next ping
  # -------------------------
  @doc "Schedule next ping with adaptive interval"
  def schedule_ping(device_id, last_rtt \\ nil) do
    interval = maybe_adaptive_interval(last_rtt)
    Logger.debug("[#{device_id}] Scheduling next ping in #{interval}ms")
    RegistryHub.schedule_ping_registry(device_id, interval)
    :ok
  end

  # -------------------------
  # Pong received from client
  # -------------------------
  def pongs_received(device_id, receive_time, state) when is_map(state) do
    last_send_ping = Map.get(state, :last_send_ping)
    rtt = if last_send_ping, do: DateTime.diff(receive_time, last_send_ping, :millisecond), else: 0

    Logger.info(
      "[#{device_id}] Pong received (RTT=#{rtt}ms). Resetting missed_pongs=0 (was #{state.missed_pongs})"
    )

    adaptive_max_missed = maybe_adaptive_max_missed(rtt)

    new_counter =
      if Map.get(state, :pong_counter, 0) + 1 >= @max_pong_counter do
        Logger.debug("[#{device_id}] Pong counter limit reached → ONLINE transition")
        cur_device_state =
          state_change(device_id, Map.get(state, :eid), "ONLINE", Map.get(state, :last_state_change), state)
        {:pr_count, 0, cur_device_state}
      else
        {:unpr_count, Map.get(state, :pong_counter, 0) + 1}
      end

    case new_counter do
      {:pr_count, counter, cur_device_state} ->
        update_state_after_increment(state, counter, 0, rtt, receive_time, cur_device_state)

      {:unpr_count, counter} ->
        {:noreply,
          %{
            state
            | missed_pongs: 0,
              pong_counter: counter,
              timer: receive_time,
              last_rtt: rtt,
              max_missed_pongs_adaptive: adaptive_max_missed,
              last_send_ping: receive_time
          }}
    end
  end

  # -------------------------
  # Pong received from network
  # -------------------------
  def handle_pong_from_network(device_id, sent_time) do
    Logger.debug("[#{device_id}] Handling network pong at #{sent_time}")
    RegistryHub.handle_pong_registry(device_id, sent_time)
  end
end
