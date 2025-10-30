defmodule Storage.DeviceStorage do
  @moduledoc """
  Storage helper for devices using Mnesia.
  - Main table: :devices (composite key {eid, device_id})
  - Secondary index table: :devices_index (key: eid, value: device_id)
  Handles saving, fetching, updating last_offset, and fetching all devices by eid.
  """

  require Logger

  @device_table :device
  @device_index_table :device_index
  # @user_awareness_table :user_awareness_table -- REMOVED

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

end



# Storage.DeviceStorage.fetch_devices_by_eid("a@domain.com")
# Storage.DeviceStorage.get_device("a@domain.com", "aaaaa1")
# Storage.DeviceStorage.check_index_by_eid("a@domain.com")
# Storage.DeviceStorage.delete_device("aaaaa1", "a@domain.com")