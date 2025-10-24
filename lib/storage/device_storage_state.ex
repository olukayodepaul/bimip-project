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

    # Awareness override takes precedence
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
        owner_override? -> "OFFLINE"
        online_devices != [] -> "ONLINE"
        true -> "OFFLINE"
      end

    {user_status, online_devices}
  end


  defp device_ids(devices) do
    devices |> Enum.map(& &1.device_id) |> Enum.sort()
  end

  # -----------------------------
  # Mnesia state updates
  # -----------------------------

  defp update_state(eid, user_status, devices, now) do
    :mnesia.transaction(fn ->
      :mnesia.write({@user_state_table, eid, %{user_status: user_status, online_devices: devices, last_seen: now}})
    end)
  end

defp bump_idle_time(eid, prev_state, now) do
    :mnesia.transaction(fn ->
      :mnesia.write({@user_state_table, eid, %{prev_state | last_seen: now}})
    end)
  end


  defp read_state(eid) do
    :mnesia.transaction(fn ->
      case :mnesia.read({@user_state_table, eid}) do
        [] -> nil
        [{@user_state_table, ^eid, state}] -> state
      end
    end)
    |> case do
      {:atomic, state} -> state
      _ -> nil
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
      # 1️⃣ First-time entry: treat as changed
      prev_state == nil ->
        update_state(owner_eid, user_status, online_devices, now)
        {:changed, user_status, online_devices}

      true ->
        prev_status = prev_state.user_status
        prev_ids = device_ids(prev_state.online_devices)
        curr_ids = device_ids(online_devices)

        cond do
          # 2️⃣ All devices disappeared → OFFLINE
          online_devices == [] and prev_status != "OFFLINE" ->
            update_state(owner_eid, "OFFLINE", [], now)
            {:changed, "OFFLINE", []}

          # 3️⃣ Still offline, nothing new
          online_devices == [] and prev_status == "OFFLINE" ->
            bump_idle_time(owner_eid, prev_state, now)
            {:unchanged, "OFFLINE", []}

          # 4️⃣ Devices appeared → ONLINE
          online_devices != [] and prev_status != "ONLINE" ->
            update_state(owner_eid, "ONLINE", online_devices, now)
            {:changed, "ONLINE", online_devices}

          # 5️⃣ Device list changed but still online
          online_devices != [] and prev_ids != curr_ids ->
            update_state(owner_eid, "ONLINE", online_devices, now)
            {:changed, "ONLINE", online_devices}

          # 6️⃣ No meaningful change
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

  def cancel_termination_if_any_device_are_online(current_timer) do
    if current_timer do
      Logger.info("Cancelled termination timer for #{current_timer}")
      Process.cancel_timer(current_timer)
    end
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
# Storage.DeviceStateChange.track_state_change("a@domain.com")
# Storage.DeviceStorage.delete_device("aaaaa2", "a@domain.com")