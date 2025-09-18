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

  @doc """
  Save a device payload and update secondary index.
  """
  def save(device_id, eid, payload, last_offset \\ 0) do
    key = {eid, device_id}
    timestamp = DateTime.utc_now()

    # Write to main devices table
    :mnesia.transaction(fn ->
      :mnesia.write({@device_table, key, payload, last_offset, timestamp})
    end)
    |> case do
      {:atomic, :ok} -> :ok
      {:aborted, reason} ->
        Logger.error("Failed to save device #{inspect(key)}: #{inspect(reason)}")
        {:error, reason}
    end

    # Write to secondary index table
    :mnesia.transaction(fn ->
      :mnesia.write({@device_index_table, eid, device_id})
    end)
    |> case do
      {:atomic, :ok} -> :ok
      {:aborted, reason} ->
        Logger.error("Failed to write index for #{inspect(eid)}: #{inspect(reason)}")
        {:error, reason}
    end
  end

  @doc """
  Fetch a device payload from the main table by {eid, device_id}.
  Returns {payload, last_offset, timestamp} or nil if not found.
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
  Returns a list of `{eid, device_id}` tuples.
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

  def fetch_devices_by_eid(eid) do
    :mnesia.transaction(fn ->
      # Step 1: Get all device_ids for this eid
      :mnesia.match_object({@device_index_table, eid, :_})
    end)
    |> case do
      {:atomic, []} ->
        []

      {:atomic, index_records} ->
        # index_records = [{:device_index, eid, device_id}, ...]
        index_records
        |> Enum.map(fn {@device_index_table, ^eid, device_id} ->
          get_device(eid, device_id)
        end)
        |> Enum.reject(&is_nil/1)

      {:aborted, reason} ->
        {:error, reason}
    end
  end

  
end
# Storage.DeviceStorage.get_devices_by_eid("a@domain.com")