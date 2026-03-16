defmodule Device.Transmission do
  @doc """
  Sends to other devices of the same user, excluding the sender.
  Filters the EID group PIDs against the valid device list.
  """
  def emit(eid, sender_device_id, all_devices, payload) when is_binary(payload) do
    # 1. Get the Master List (Source of Truth)
    online_pids = :pg.get_members(BimipGroups, "device_#{eid}")

    if online_pids != [] do
      # 2. Build a Set of PIDs belonging to valid target devices
      valid_pids = build_valid_pid_set(all_devices, sender_device_id, eid)

      # 3. Filter and Send (Single pass over online PIDs)
      online_pids
      |> Enum.filter(&MapSet.member?(valid_pids, &1))
      |> Enum.each(&send(&1, {:outbound, payload}))
    end
    :ok
  end

  @doc """
  Broadcasts to all valid devices under the EID.
  """
  def emit_broadcast(eid, all_devices, bin) when is_binary(bin) do
    online_pids = :pg.get_members(BimipGroups, "device_#{eid}")

    if online_pids != [] do
      valid_pids = build_valid_pid_set(all_devices, nil, eid)

      online_pids
      |> Enum.filter(&MapSet.member?(valid_pids, &1))
      |> Enum.each(&send(&1, {:outbound, bin}))
    end
    :ok
  end

  # Internal helper to find PIDs for non-stale/active devices
  defp build_valid_pid_set(all_devices, exclude_id, eid) do
    now = System.system_time(:second)
    stale_limit = Settings.Connections.stale_threshold_seconds()

    all_devices
    |> Enum.reduce(MapSet.new(), fn {id, dev}, acc ->
      if id != exclude_id and (now - dev.last_seen) <= stale_limit and dev.presence == 1 do
        # Get PIDs for this specific device and add to the set
        pids = :pg.get_members(BimipGroups, "device_#{dev.device_id}_#{eid}")
        Enum.reduce(pids, acc, fn pid, set_acc -> MapSet.put(set_acc, pid) end)
      else
        acc
      end
    end)
  end

  def emit_single(target_device_id, eid, payload) when is_binary(payload) do
    # Direct lookup in the cluster-wide process group
    BimipGroups
    |> :pg.get_members("device_#{target_device_id}_#{eid}")
    |> Enum.each(fn pid ->
      send(pid, {:outbound, payload})
    end)
    :ok
  end

end
