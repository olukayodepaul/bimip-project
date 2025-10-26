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
  @user_awareness_table :user_awareness_table
  @doc """
  Save a device payload and update secondary index.
  """

  #change this to local file at version two
  def register_device_session(device_id, eid, payload, last_offset \\ 0) do
    key = {eid, device_id}
    timestamp = DateTime.utc_now()

    case :mnesia.transaction(fn ->
          case :mnesia.read(@device_table, key) do
            [] ->
              # New insert
              new_payload =
                payload
                |> Map.put(:last_seen, timestamp)
                |> Map.put(:status_source, "LOGIN")

              :mnesia.write({@device_table, key, new_payload, last_offset, timestamp})
              Map.get(new_payload, :awareness_intention, 2)

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

              :mnesia.write({@device_table, key, updated_payload, old_offset, timestamp})
              Map.get(updated_payload, :awareness_intention, 2) #The awareness is not use

          end
        end) do
      {:atomic, awareness} ->
        :mnesia.transaction(fn ->
          :mnesia.write({@device_index_table, eid, device_id})
        end)

        {:ok, awareness}

      {:aborted, reason} ->
        Logger.error("Failed to save device #{inspect(key)}: #{inspect(reason)}")
        {:error, reason}
    end
  end

  def insert_awareness(eid, awareness \\ 2) do
    key = {eid}
    timestamp = DateTime.utc_now()

    :mnesia.transaction(fn ->
      case :mnesia.read({@user_awareness_table, key}) do
        [] ->
          # eid not found → insert with default awareness = 2
          :mnesia.write({@user_awareness_table, key, 2, timestamp})

        _ ->
          # eid already exists → update normally
          :mnesia.write({@user_awareness_table, key, awareness, timestamp})
      end
    end)
    |> case do
      {:atomic, _result} ->
        {:ok, :updated}

      {:aborted, reason} ->
        {:error, reason}
    end
  end

  def fetch_user_awareness(eid) do
    key = {eid}

    :mnesia.transaction(fn ->
      case :mnesia.read({@user_awareness_table, key}) do
        [{@user_awareness_table, ^key, awareness,  _timestamp}] ->
          {:ok, awareness}

        [] ->
          {:error, :not_found}
      end
    end)
    |> case do
      {:atomic, result} -> result
      {:aborted, reason} -> {:error, reason}
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

  # your fetch function
  def fetch_devices_by_eid(eid) do
    :mnesia.transaction(fn ->
      :mnesia.match_object({@device_index_table, eid, :_})
    end)
    |> case do
      {:atomic, []} ->
        []

      {:atomic, index_records} ->
        index_records
        |> Enum.map(fn {@device_index_table, ^eid, device_id} ->
          get_device(eid, device_id)
        end)
        |> Enum.reject(&is_nil/1)
        |> Enum.map(&normalize_device/1)

      {:aborted, reason} ->
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