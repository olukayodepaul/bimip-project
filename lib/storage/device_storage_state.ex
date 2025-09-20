defmodule Storage.DeviceStateChange do
  @moduledoc """
  Tracks user-level presence by aggregating per-device statuses,
  respecting awareness_intention and last_seen thresholds.
  """

  alias Storage.DeviceStorage
  alias Settings.ServerState
  require Logger

  @stale_threshold_seconds ServerState.stale_threshold_seconds()
  @user_state_table :track_eid_state

  # -----------------------------
  # Internal helpers
  # -----------------------------
  defp user_status_with_devices(owner_eid) do
    now = DateTime.utc_now()
    devices = DeviceStorage.fetch_devices_by_eid(owner_eid)

    owner_override? =
      Enum.any?(devices, fn d -> d.awareness_intention == 1 end)

    online_devices =
      if owner_override? do
        []
      else
        devices
        |> Enum.filter(fn d ->
          d.status == "ONLINE" and
          DateTime.diff(now, d.last_seen) <= @stale_threshold_seconds
        end)
        |> Enum.sort_by(& &1.last_seen, {:desc, DateTime})
      end

    user_status =
      cond do
        owner_override? -> :offline
        online_devices != [] -> :online
        true -> :offline
      end

    {user_status, online_devices}
  end



  defp device_ids(devices), do: Enum.map(devices, & &1.device_id) |> Enum.sort()

  # -----------------------------
  # Mnesia state updates
  # -----------------------------
  defp update_state(eid, status, devices, now) do
    :mnesia.transaction(fn ->
      :mnesia.write({@user_state_table, eid, %{
        user_status: status,
        online_devices: devices,
        last_change_at: now,
        last_seen: now
      }})
    end)
  end

  defp bump_idle_time(eid, prev_state, now) do
    :mnesia.transaction(fn ->
      :mnesia.write({@user_state_table, eid, %{prev_state | last_seen: now}})
    end)
  end

  defp read_state(eid) do
    case :mnesia.transaction(fn -> :mnesia.read({@user_state_table, eid}) end) do
      {:atomic, [{@user_state_table, ^eid, state}]} -> state
      {:atomic, []} -> nil
      {:aborted, reason} -> {:error, reason}
    end
  end

  # -----------------------------
  # Public API
  # -----------------------------
  def track_state_change(owner_eid) do
    now = DateTime.utc_now()
    {user_status, online_devices} = user_status_with_devices(owner_eid)
    prev_state = read_state(owner_eid)

    cond do
      prev_state == nil ->
        update_state(owner_eid, user_status, online_devices, now)
        {:changed, user_status, online_devices}

      true ->
        prev_status = prev_state.user_status
        prev_ids    = device_ids(prev_state.online_devices)
        curr_ids    = device_ids(online_devices)

        cond do
          prev_status != user_status ->
            update_state(owner_eid, user_status, online_devices, now)
            {:changed, user_status, online_devices}

          user_status == prev_status and prev_ids != curr_ids ->
            bump_idle_time(owner_eid, prev_state, now)
            {:unchanged, user_status, online_devices}

          true ->
            bump_idle_time(owner_eid, prev_state, now)
            {:unchanged, user_status, online_devices}
        end
    end
  end

  # -----------------------------
  # Termination scheduling
  # -----------------------------
  def schedule_termination_if_all_offline(%{eid: eid, current_timer: current_timer} = state) do
    now = DateTime.utc_now()
    devices = DeviceStorage.fetch_devices_by_eid(eid)

    online_devices =
      devices
      |> Enum.filter(fn d -> d.status == "ONLINE" end)

    if current_timer, do: Process.cancel_timer(current_timer)

    if online_devices == [] do
      latest_last_seen =
        devices
        |> Enum.map(& &1.last_seen)
        |> Enum.max(fn -> now end)

      diff = DateTime.diff(now, latest_last_seen)
      remaining_seconds = max(@stale_threshold_seconds - diff, 0)
      grace_period_ms = remaining_seconds * 1000

      Logger.warning(
        "All devices offline. Scheduling termination in #{grace_period_ms} ms " <>
        "(stale_threshold: #{@stale_threshold_seconds}s, last_seen diff: #{diff}s)"
      )

      timer_ref = Process.send_after(self(), :terminate, grace_period_ms)
      {:noreply, %{state | current_timer: timer_ref}}
    else
      Logger.info("There are still online devices. No termination scheduled.")
      {:noreply, %{state | current_timer: nil}}
    end
  end

  def cancel_termination_if_all_offline(state, awareness) do
    if state.current_timer do
      Process.cancel_timer(state.current_timer)
      Logger.info("Cancelled termination timer for #{state.eid}")
    end
    {:noreply, %{state | current_timer: nil, awareness: awareness}}
  end

  def remaining_active_devices?(eid) do
    now = DateTime.utc_now()
    benchmark_time = DateTime.add(now, -@stale_threshold_seconds, :second)

    DeviceStorage.fetch_devices_by_eid(eid)
    |> Enum.filter(fn d ->
      d.status == "ONLINE" and
        case d.last_seen do
          nil -> false
          last_seen -> DateTime.compare(last_seen, benchmark_time) == :gt
        end
    end)
    |> case do
      [] -> false
      _ -> true
    end
  end
  
end

# Storage.DeviceStateChange.remaining_active_devices?("a@domain.com")
# Storage.DeviceStorage.get_device("a@domain.com", "aaaaa2")
# Storage.DeviceStorage.delete_device("aaaaa2", "a@domain.com")