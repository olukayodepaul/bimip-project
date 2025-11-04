defmodule Storage.DeviceStorage do
  @moduledoc """
  Storage helper for devices using Mnesia.
  - Main table: :devices (composite key {eid, device_id})
  - Secondary index table: :devices_index (key: eid, value: device_id)
  Handles saving, fetching, updating last_offset, and fetching all devices by eid.
  """

  require Logger
  alias Settings.ServerState

  @device_table :device
  @device_index_table :device_index

  @doc """
  Save a device payload and update secondary index.
  OPTIMIZED: Uses a single Mnesia transaction for both device and index writes to ensure atomicity.
  """
  def register_device_session(device_id, eid, payload, last_offset \\ 0) do
    key = {eid, device_id}
    timestamp = DateTime.utc_now()

    # Consolidated into a single transaction (TX) for atomicity
    case :mnesia.transaction(fn ->
          # 1. Handle device read/write logic
          {_record, awareness} =
            case :mnesia.read(@device_table, key) do
              [] ->
                # New insert
                new_payload =
                  payload
                  |> Map.put(:last_seen, timestamp)
                  |> Map.put(:status_source, "LOGIN")

                record = {@device_table, key, new_payload, last_offset, timestamp}
                :mnesia.write(record)
                {record, Map.get(new_payload, :awareness_intention, 2)}

              [{@device_table, ^key, old_payload, old_offset, _old_ts}] ->
                # Update only selective fields + bump last_seen
                updated_payload =
                  old_payload
                  |> Map.put(:status, payload.status)
                  |> Map.put(:ip_address, payload.ip_address)
                  |> Map.put(:app_version, payload.app_version)
                  |> Map.put(:os, payload.os)
                  |> Map.put(:last_seen, timestamp)
                  |> Map.put(:status_source, "LOGIN")

                record = {@device_table, key, updated_payload, old_offset, timestamp}
                :mnesia.write(record)
                {record, Map.get(updated_payload, :awareness_intention, 2)}
            end

          # 2. Write to the secondary index within the same TX
          :mnesia.write({@device_index_table, eid, device_id})
          # Return the result
          awareness
        end) do
      {:atomic, awareness} ->
        {:ok, awareness}

      {:aborted, reason} ->
        Logger.error("Failed to register device session #{inspect(key)}: #{inspect(reason)}")
        {:error, reason}
    end
  end

  def update_device_status(device_id, eid, status_source, status \\ "ONLINE") do
    key = {eid, device_id}
    now = DateTime.utc_now()

    case :mnesia.transaction(fn ->
          case :mnesia.read(@device_table, key) do
            [{@device_table, ^key, old_payload, old_offset, _old_ts}] ->
              updated_payload =
                old_payload
                |> Map.put(:status_source, status_source)
                |> Map.put(:status, status)
                |> Map.put(:last_activity, now)
                |> Map.put(:last_seen, now)

              :mnesia.write({@device_table, key, updated_payload, old_offset, now})
              :ok

            [] ->
              {:error, :not_found}
          end
        end) do
      {:atomic, :ok} -> :ok
      {:atomic, {:error, :not_found}} -> {:error, :not_found}
      {:aborted, reason} -> {:error, reason}
    end
  end

  @doc """
  Fetch a device payload from the main table by {eid, device_id}.
  """
  def get_device(eid, device_id) do
    key = {eid, device_id}

    :mnesia.transaction(fn ->
      case :mnesia.read({@device_table, key}) do
        [] -> nil
        [record] -> record
      end
    end)
    |> case do
      {:atomic, result} -> result
      {:aborted, reason} -> {:error, reason}
    end
  end

  @doc """
  Fetch all entries in the secondary index table for a given `eid`.
  """
  def check_index_by_eid(eid) do
    :mnesia.transaction(fn ->
      :mnesia.match_object({@device_index_table, eid, :_})
    end)
    |> case do
      {:atomic, records} -> records
      {:aborted, reason} -> {:error, reason}
    end
  end

  @doc """
  Fetch only the last_offset for a device.
  """
  def get_last_offset(device_id, eid) do
    key = {eid, device_id}

    case :mnesia.transaction(fn -> :mnesia.read({@device_table, key}) end) do
      {:atomic, [{@device_table, ^key, _payload, last_offset, _timestamp}]} -> last_offset
      {:atomic, []} -> nil
      {:aborted, reason} -> {:error, reason}
    end
  end

  @doc """
  Update last_offset for a device without modifying the payload.
  """
  def update_last_offset(eid, device_id, new_offset) do
    key = {eid, device_id}

    :mnesia.transaction(fn ->
      case :mnesia.read({@device_table, key}) do
        [{@device_table, ^key, payload, _old_offset, timestamp}] ->
          :mnesia.write({@device_table, key, payload, new_offset, timestamp})
          :ok

        [] ->
          {:error, :not_found}
      end
    end)
  end

  @doc """
  Fetch all devices for a given EID.
  OPTIMIZED: All index and device data reads are consolidated into a single Mnesia transaction.
  """
  def fetch_devices_by_eid(eid) do
    # All reads happen in ONE transaction for fast, scalable fetch
    :mnesia.transaction(fn ->
      # 1. Fetch all index records (device IDs)
      index_records = :mnesia.match_object({@device_index_table, eid, :_})

      # 2. Iterate and read device data *inside* the same transaction
      index_records
      |> Enum.flat_map(fn {@device_index_table, ^eid, device_id} ->
        key = {eid, device_id}
        case :mnesia.read({@device_table, key}) do
          [] -> []
          [record] -> [record]
        end
      end)
    end)
    |> case do
      {:atomic, device_records} ->
        # 3. Normalize records outside the transaction
        device_records
        |> Enum.map(&normalize_device/1)

      {:aborted, reason} ->
        Logger.error("Failed to fetch devices for EID #{eid}: #{inspect(reason)}")
        {:error, reason}
    end
  end

  # 👇 Define helper in same module
  defp normalize_device({:device, {eid, device_id}, attrs, last_offset, ts}) do
    attrs
    |> Map.put(:eid, eid)
    |> Map.put(:device_id, device_id)
    |> Map.put(:last_offset, last_offset)
    |> Map.put(:timestamp, ts)
  end

  def delete_device(device_id, eid) do
    key = {eid, device_id}

    :mnesia.transaction(fn ->
      # Delete from primary table
      :mnesia.delete({@device_table, key})

      # Delete only the matching entry in the index
      :mnesia.delete_object({@device_index_table, eid, device_id})
    end)
    |> case do
      {:atomic, _} -> :ok
      {:aborted, reason} -> {:error, reason}
    end
  end

  @doc """
  Check overall user presence based on all their devices.
  - Returns "ONLINE" if at least one device is active within the stale threshold.
  - Returns "OFFLINE" if all devices are stale/offline or awareness is disabled.
  """
  def user_presence_status(eid) do
    now = DateTime.utc_now()
    stale_threshold = ServerState.stale_threshold_seconds()

    case fetch_devices_by_eid(eid) do
      {:error, _} -> "OFFLINE"
      [] -> "OFFLINE"
      devices when is_list(devices) ->
        owner_override? =
          Enum.any?(devices, fn d -> d.awareness_intention == 1 end)

        cond do
          owner_override? ->
            "OFFLINE"

          Enum.any?(devices, fn d ->
            d.status == "ONLINE" and
              DateTime.diff(now, d.last_seen) <= stale_threshold
          end) ->
            "ONLINE"

          true ->
            "OFFLINE"
        end
    end
  end


  @doc """
  Check if there are any currently active devices for a given `eid`.
  Returns `true` if at least one device is ONLINE and seen within the stale threshold,
  otherwise `false`.
  """
  def remaining_active_devices?(eid) do
    now = DateTime.utc_now()
    stale_threshold = Settings.ServerState.stale_threshold_seconds()
    benchmark_time = DateTime.add(now, -stale_threshold, :second)

    case fetch_devices_by_eid(eid) do
      {:error, _} ->
        false

      [] ->
        false

      devices when is_list(devices) ->
        Enum.any?(devices, fn d ->
          d.status == "ONLINE" and
            d.last_seen != nil and
            DateTime.compare(d.last_seen, benchmark_time) == :gt
        end)
    end
  end

  # -----------------------------
  # Termination scheduling
  # -----------------------------
  @doc """
  Schedule termination if all devices for the given user (EID) are offline.
  Cancels any existing timer before scheduling a new one.
  Waits for the remaining grace period based on the last_seen timestamp.
  """
  def schedule_termination_if_all_offline(%{eid: eid, current_timer: current_timer} = state) do
    now = DateTime.utc_now()
    devices = fetch_devices_by_eid(eid)
    stale_threshold = Settings.ServerState.stale_threshold_seconds()

    online_devices =
      case devices do
        {:error, _} -> []
        _ -> Enum.filter(devices, fn d -> d.status == "ONLINE" end)
      end

    if current_timer, do: Process.cancel_timer(current_timer)

    if online_devices == [] do
      latest_last_seen =
        devices
        |> Enum.map(& &1.last_seen)
        |> Enum.max(fn -> now end)

      diff = DateTime.diff(now, latest_last_seen)
      remaining_seconds = max(stale_threshold - diff, 0)
      grace_period_ms = remaining_seconds * 1000

      Logger.warning(
        "All devices offline. Scheduling termination in #{grace_period_ms} ms " <>
          "(stale_threshold: #{stale_threshold}s, last_seen diff: #{diff}s)"
      )

      timer_ref = Process.send_after(self(), :terminate, grace_period_ms)
      {:noreply, %{state | current_timer: timer_ref}}
    else
      Logger.info("There are still online devices. No termination scheduled.")
      {:noreply, %{state | current_timer: nil}}
    end
  end

  @doc """
  Cancels a termination timer if any device is still online.
  """
  def cancel_termination_if_any_device_are_online(current_timer) do
    if current_timer do
      Logger.info("Cancelled termination timer for #{inspect(current_timer)}")
      Process.cancel_timer(current_timer)
    end
  end

end

# Storage.DeviceStorage.fetch_devices_by_eid("a@domain.com")
# Storage.DeviceStorage.get_device("a@domain.com", "aaaaa1")
# Storage.DeviceStorage.check_index_by_eid("a@domain.com")
# Storage.DeviceStorage.delete_device("aaaaa1", "a@domain.com")