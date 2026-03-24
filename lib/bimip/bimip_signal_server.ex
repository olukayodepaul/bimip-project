defmodule Bimip.SignalServer do
  use GenServer
  require Logger

  @message_route_id 6
  @partition 1
  @range 100
  @route 8
  @stale_threshold 1800 # 30 minutes in seconds
  @global_ttl_ms 24 * 3600 * 1000 # 24 hours in milliseconds


  alias Supervisor.{Registry, Client}
  alias Bimip.{Flow, MessageScheme,  Body}

  # ----------------------
  # Client API
  # ----------------------
  def start_link(%{eid: eid} = state) do
    GenServer.start_link(__MODULE__, state, name: Registry.via_monitor_registry(eid))
  end

  # ----------------------
  # Server Callbacks
  # ----------------------

  @impl true
  def init(%{eid: eid, device_id: device_id, ws_pid: ws_pid, exp: exp, uupid: uupid}) do

    now = System.system_time(:second)
    initial_timer = Process.send_after(self(), :expire_genserver, @global_ttl_ms)

    initial_state = %{
      eid: eid,
      current_timer: nil,
      force_stale: now,
      last_activity: now,
      devices: %{},
      sub: MapSet.new(),  # Populated via RosterManager
      roster: %{},       # Populated via RosterManager
      sync_status: :pending,
      awareness: %{
        presence: 0,
        presence_stale: System.system_time(:second)
      },
      flow: [],
      termination_timer: initial_timer,
    }

    Bimip.Signal.RosterManager.start_link(eid, self())
    :ok = :pg.join(BimipGroups, "eid_#{eid}", self())
    Bimip.Broker.Server.user_topic(eid)
    {:ok, initial_state, {:continue, {:start_device, {eid, device_id, exp, ws_pid, uupid}}}}
  end

  @impl true
  def handle_continue({:start_device, args}, state) do
    # Capture the result of the cast (which contains the new state with the device)
    {:noreply, updated_state} = handle_cast({:start_device, args}, state)

    # Return the updated state so the GenServer actually saves it
    {:noreply, updated_state}
  end

  @impl true
  def handle_info({:roster, list}, state) do
    # Update rich metadata
    new_roster = Enum.reduce(list, state.roster, fn sub, acc ->
      Map.put(acc, sub.eid, sub)
    end)

    # Update validation MapSet
    new_sub_set = list
                  |> Enum.map(& &1.eid)
                  |> MapSet.new()
                  |> MapSet.union(state.sub)

    # Trigger Broker subscription for these newly discovered friends
    Bimip.Broker.Server.subscribe_to_users(Enum.map(list, & &1.eid))
    {:noreply, %{state | roster: new_roster, sub: new_sub_set}}
  end

  @impl true
  def handle_info(:roster_sync_complete, state) do
    {:noreply, %{state | sync_status: :ready}}
  end

  @impl true
  def handle_cast({:start_device, {eid, device_id, exp, ws_pid, uupid}}, state) do
    case Client.start_session({eid, device_id, exp, ws_pid, uupid}) do
      {:ok, _pid} ->
        now = System.system_time(:second)

        device_info = %{
          ws_pid: ws_pid, device_id: device_id, eid: eid, uupid: uupid,
          last_seen: now, token_expiration: exp
        }

        state_with_device = update_in(state, [:devices, device_id], fn
          nil -> device_info
          existing -> %{existing | ws_pid: ws_pid, last_seen: now, token_expiration: exp}
        end)

        {:noreply, update_last_seen(state_with_device, device_id)}

      {:error, reason} ->
        Logger.error("Failed to start device #{device_id} for #{eid}: #{inspect(reason)}")
        {:noreply, state}
    end
  end

  @impl true
  def handle_cast({:message, %{message: message, device_id: device_id} = message_builder}, state) do
    case subscribers_validation(message.to.eid, state.sub) do
      {:ok, :success} ->

        filter_roster = Map.take(state.roster, [message.to.eid])

        Task.Supervisor.start_child(Message.TaskSupervisor, fn ->
          t1 = Task.async(fn -> Message.Broker.sender(message_builder, state.devices) end)
          t2 = Task.async(fn -> Message.Broker.recv(message_builder, filter_roster) end)
          Task.await(t1); Task.await(t2)
        end)

      {:error, :failed} ->
        reason = "Field 'to.eid' → #{message.to.eid} Invalid subscriber 500"
        ThrowProtocolErrorSchema.build(@message_route_id, reason, Until.UniPosTime.response_time())
        |> then(&Device.Transmission.emit_single(device_id, state.eid, &1))
    end

    {:noreply, update_last_seen(state, device_id)}
  end

  @impl true
  def handle_cast({:flow, %{flow: %Bimip.Flow{} = flow_data, device_id: device_id}}, state) do
    # 1. Background purge: keep only what is NOT expired
    {_active, state} = fetch_active_and_purge_expired(state)

    # 2. Add the new entry with a fresh TTL
    now = System.system_time(:second)
    expiry_timestamp = now + div(total_ttl_ms(), 1000)
    new_entry = %{flow_data | ttl: expiry_timestamp}

    %MessageScheme{
      route_id: 10,
      payload: {:body, %Body{
        route_id: @route,
        flow: [flow_data], # <--- Only the fresh status
        timestamp: Until.UniPosTime.uni_pos_time()
      }}
    }
    |> MessageScheme.encode()
    |> then(&Bimip.Broker.Server.broadcast_to_user(state.eid, {:presence_update, {state.eid, &1, 2, 1}}))

    new_state =
      %{state | flow: [new_entry | state.flow]}
      |> update_last_seen(device_id)

    {:noreply, new_state}
  end

  defp fetch_active_and_purge_expired(state) do
    now = System.system_time(:second)

    # Split: 'expired' (rejected), 'active' (kept/fetched)
    {expired, active} = Enum.split_with(state.flow, fn entry ->
      entry.ttl <= now
    end)

    # Return the active flows and the state with ONLY those active flows
    {active, %{state | flow: active}}
  end

  defp user_online?(eid) do
    case :pg.get_members(BimipGroups, "eid_#{eid}") do
      [] -> false
      _ -> true
    end
  end

  @impl true
  def handle_cast({:message_transmiter, message_builder}, state) do
    Device.Transmission.emit(state.eid, 0, state.devices, message_builder)
    {:noreply, state}
  end

  defp subscribers_validation(subscriber_eid, sub) do
    if subscriber_eid in sub, do: {:ok, :success}, else: {:error, :failed}
  end

  @impl true
  def handle_cast({:data_stream, binary}, state) do
    Device.Transmission.emit(state.eid, 0, state.devices, binary)
    {:noreply, state}
  end

  @impl true
  def handle_cast({:offset_commit, data}, state) do
    Commit.Offset.offset_commit(data)
    new_state = update_last_seen(state, data.device_id)
    {:noreply, new_state}
  end

  @impl true
  def handle_cast({:terminate, _device_id}, state) do
    {:stop, :normal, state}
  end

  @impl true
  def handle_cast({:broadcast, {bin, uupid, offset, presence, device_id, broadcast}}, state) do

    if presence == 1 do
      push_message(state.eid, uupid, offset, device_id)
    end

    if broadcast_valid?(state.awareness, presence) do

      Bimip.Broker.Server.broadcast_to_user(state.eid, {:presence_update, {state.eid, bin, broadcast, presence}})

      new_state =
        state
        |> update_awareness_state(presence)
        |> update_last_seen(device_id)

        {:noreply, new_state}
    else
      {:noreply, update_last_seen(state, device_id)}
    end

  end

  @impl true
  def handle_cast({:update_device_last_seen, %{device_id: device_id}}, state) do
    new_state = update_last_seen(state, device_id)
    {:noreply, new_state}
  end

  @impl true
  def handle_info({:presence_update, {eid, bin, broadcast, presence} }, state) do

    state = update_roster_last_seen(state, eid, presence)

    {active_flows, state} = fetch_active_and_purge_expired(state)

    if broadcast == 2 do
       Device.Transmission.emit_broadcast(state.eid, state.devices, bin)
    end

    unless Enum.empty?(active_flows) do
      %MessageScheme{
        route_id: 10,
          payload: {:body, %Body{
            route_id: @route,
            flow: active_flows,
            timestamp: Until.UniPosTime.uni_pos_time()
          }
        }
      }
      |>MessageScheme.encode()
      |>then(&Route.Connect.client_server_inbound({:eid, eid, :message_transmiter, &1}))
    end

    {:noreply, state}
  end

  defp push_message(eid, uupid, offset, device_id) do
    Queue.QueueLogImpl.acknowledge(eid, uupid, offset)

    case Queue.QueueLogImpl.fetch_batch(eid, @partition, uupid, Application.Config.max_batch_size()) do
      {:ok, []} ->
        :ok

      {:ok, messages} ->
        %Bimip.MessageScheme{
          route_id: 10,
          payload:
            {:body,
             %Bimip.Body{
               route_id: 6,
               messages: messages,
               timestamp: System.system_time(:millisecond)
             }}
        }
        |> Bimip.MessageScheme.encode()
        |> then(&Device.Transmission.emit_single(device_id, eid, &1))

      _error ->
        :error
    end
  end

  defp update_last_seen(state, device_id) do
    now = System.system_time(:second)

    # Cancel the old timer
    if state.termination_timer, do: Process.cancel_timer(state.termination_timer)

    # Start the 32-minute timer (2m Active + 30m Stale Threshold)
    new_timer = Process.send_after(self(), :expire_genserver, total_ttl_ms())

    new_state = %{state | last_activity: now, termination_timer: new_timer}

    update_in(new_state, [:devices, device_id], fn
      nil -> nil
      device -> %{device | last_seen: now}
    end)
  end

  defp update_awareness_state(state, presence) do
    %{state | awareness: %{
        presence: presence,
        presence_stale: System.system_time(:second)
      }
    }
  end

  defp update_roster_last_seen(state, target_eid, presence) do
    now = System.system_time(:second)

    # Changed :roaster -> :roster to match your state map
    update_in(state.roster, fn roster_map ->
      case Map.get(roster_map, target_eid) do
        nil ->
          roster_map
        user_meta ->
          Map.put(roster_map, target_eid, %{user_meta | last_seen: now, presence: presence})
      end
    end)
  end

  defp broadcast_valid?(awareness, new_presence) do
    now = System.system_time(:second)
    time_diff = now - awareness.presence_stale

    # Logic:
    # 1. If presence changed (e.g. 0 -> 1), we MUST broadcast.
    # 2. If presence is the same, we ONLY broadcast if time_diff > threshold.
    cond do
      new_presence != awareness.presence ->
        true

      new_presence == awareness.presence and time_diff > @stale_threshold ->
        true

      true ->
        false
    end
  end

  @impl true
  def handle_info(:expire_genserver, state) do
    now = System.system_time(:second)
    elapsed = now - state.last_activity

    # Threshold in seconds: 120s + 1800s = 1920s
    limit_sec = div(total_ttl_ms(), 1000)

    if elapsed >= limit_sec do
      Logger.info("SignalServer for #{state.eid} idle beyond stale threshold. Shutting down.")
      {:stop, :normal, state}
    else
      # If activity happened that wasn't caught, reschedule for the remainder
      remaining_ms = (limit_sec - elapsed) * 1000
      new_timer = Process.send_after(self(), :expire_genserver, remaining_ms)

      # Use hibernate to save RAM during the remaining grace period
      {:noreply, %{state | termination_timer: new_timer}, :hibernate}
    end
  end

  @impl true
  def terminate(reason, state) do
    case reason do
      :normal ->
        Logger.info("SignalServer for #{state.eid} shut down normally (TTL expired).")
      _ ->
        Logger.error("SignalServer for #{state.eid} crashed. Reason: #{inspect(reason)}")
    end
    :ok
  end

  defp total_ttl_ms, do: @global_ttl_ms + (@stale_threshold * 1000)

end
