defmodule Util.Client.DeviceState do
  @moduledoc """
  Tracks device state changes using the same logic as ETS, but keeps state in the GenServer.

  Rules:
    - awareness_intention = 1 => device forced OFFLINE
    - Otherwise: device ONLINE if status == "ONLINE" and last_seen within stale threshold
    - Changes emitted only if:
        * device_status flips, OR
        * forced heartbeat triggers after idle too long
  """
  alias Settings.AppDeviceState
  require Logger

  @stale_threshold_seconds AppDeviceState.stale_threshold_seconds()
  @force_change_seconds AppDeviceState.force_change_seconds()

  @doc """
  Compare current device_state with incoming attrs, return three values:
  - :changed | :refresh | :unchanged
  - new_state to store in GenServer
  - new_device_state equivalent to what ETS would have stored
  """
  def track_state_change(attrs, device_state) do
    now = DateTime.utc_now()

    # Determine current status
    curr_status =
      cond do
        attrs.awareness_intention == 1 ->
          "OFFLINE"

        attrs.status == "ONLINE" and DateTime.diff(now, attrs.last_seen) <= @stale_threshold_seconds ->
          "ONLINE"

        true ->
          "OFFLINE"
      end

    prev_status = device_state.device_status

    idle_too_long? =
      case device_state.last_activity do
        nil -> false
        last_activity -> DateTime.diff(now, last_activity) >= @force_change_seconds
      end

    # Build ETS-equivalent state (what we would have saved in ETS)
    cond do
      prev_status != curr_status ->
        # Status changed
        new_state = Map.merge(device_state, %{
          device_status: curr_status,
          last_change_at: now,
          last_seen: attrs.last_seen,
          last_activity: now
        })

        Logger.info("[DeviceState] Status changed from #{prev_status} → #{curr_status}")
        {:changed, curr_status, new_state}

      idle_too_long? ->
        # Forced refresh after idle timeout
        new_state = Map.merge(device_state, %{
          last_change_at: now,
          last_seen: attrs.last_seen,
          last_activity: now
        })

        Logger.debug("[DeviceState] Forced refresh after idle timeout for status #{prev_status}")
        {:refresh, prev_status, new_state}

      true ->
        # No change
        new_state = Map.merge(device_state, %{
          last_seen: attrs.last_seen
        })

        Logger.debug("[DeviceState] No change for device (status #{curr_status})")
        {:unchanged, curr_status, new_state}
    end
  end
end
