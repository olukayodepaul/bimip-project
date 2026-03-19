defmodule Bimip.SignalServer do
  use GenServer
  require Logger

  @message_route_id 6
  @partition 1
  @range 100

  alias Supervisor.{Registry, Client}
  alias Route.Connect

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

    initial_state = %{
      eid: eid,
      current_timer: nil,
      force_stale: System.system_time(:second),
      devices: %{},
      sub: MapSet.new(),  # Populated via RosterManager
      roster: %{},       # Populated via RosterManager
      sync_status: :pending
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
    Logger.info("SignalServer: Roster sync finished for #{state.eid}")
    {:noreply, %{state | sync_status: :ready}}
  end

  @impl true
  def handle_cast({:start_device, {eid, device_id, exp, ws_pid, uupid}}, state) do
    case Client.start_session({eid, device_id, exp, ws_pid, uupid}) do
      {:ok, _pid} ->
        now = System.system_time(:second)

        device_info = %{
          ws_pid: ws_pid, device_id: device_id, eid: eid, uupid: uupid,
          last_seen: now, token_expiration: exp, presence: 1
        }

        new_state = update_in(state, [:devices, device_id], fn
          nil -> device_info
          existing -> %{existing | ws_pid: ws_pid, last_seen: now, token_expiration: exp}
        end)

        {:noreply, new_state}

      {:error, reason} ->
        Logger.error("Failed to start device #{device_id} for #{eid}: #{inspect(reason)}")
        {:noreply, state}
    end
  end

  @impl true
  def handle_cast({:message, %{message: message, device_id: device_id} = message_builder}, state) do
    case subscribers_validation(message.to.eid, state.sub) do
      {:ok, :success} ->
        # Trigger push if recipient is not online in Process Groups
        unless user_online?(message.to.eid) do
          case Map.get(state.roster, message.to.eid) do
            nil -> :ok # Data chunk hasn't arrived yet
            meta -> trigger_push(meta, message)
          end
        end

        Task.Supervisor.start_child(Message.TaskSupervisor, fn ->
          t1 = Task.async(fn -> Message.Broker.sender(message_builder, state.devices) end)
          t2 = Task.async(fn -> Message.Broker.recv(message_builder) end)
          Task.await(t1); Task.await(t2)
        end)

      {:error, :failed} ->
        reason = "Field 'to.eid' → #{message.to.eid} Invalid subscriber 500"
        ThrowProtocolErrorSchema.build(@message_route_id, reason, Until.UniPosTime.response_time())
        |> then(&Route.Connect.outbouce(device_id, &1))
    end

    {:noreply, update_last_seen(state, device_id)}
  end

  defp trigger_push(meta, _message) do
    # This pulls the 6 fields we documented in the RosterManager
    %{d_tok: token, plat: platform, app_id: app_id, eid: eid} = meta

    Logger.info("Triggering offline push for #{eid} on platform: #{platform}")

    # Here you call your actual Push Notification Service
    # e.g., Bimip.Push.send_notification(token, platform, app_id)
    :ok
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
  def handle_cast({:awareness, uupid, offset, presence, device_id}, state) do
    if presence == 1 do
      push_message(state.eid, uupid, offset, device_id)
    end

    new_state = update_device_presence(state, device_id, presence)
    {:noreply, new_state}
  end

  @impl true
  def handle_cast({:broadcast, {bin, uupid, offset, presence, device_id}}, state) do
    Bimip.Broker.Server.broadcast_to_user(state.eid, {:presence_update, {state.eid, bin} })

    if presence == 1 do
      push_message(state.eid, uupid, offset, device_id)
    end

    new_state = update_device_presence(state, device_id, presence)
    {:noreply, new_state}
  end

  @impl true
  def handle_cast({:update_device_last_seen, %{device_id: device_id}}, state) do
    new_state = update_last_seen(state, device_id)
    {:noreply, new_state}
  end

  @impl true
  def handle_info({:presence_update, {eid, bin} }, state) do
    new_state = update_roster_last_seen(state, eid)
    Device.Transmission.emit_broadcast(state.eid, state.devices, bin)
    {:noreply, new_state}
  end

  defp subscribers_validation(subscriber_eid, sub) do
    if subscriber_eid in sub, do: {:ok, :success}, else: {:error, :failed}
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
        |> then(&Connect.outbouce(device_id, &1))

      _error ->
        :error
    end
  end

  defp update_device_presence(state, device_id, presence) do
    now = System.system_time(:second)

    update_in(state, [:devices, device_id], fn
      nil -> nil
      device -> %{device | last_seen: now, presence: presence}
    end)
  end

  defp update_last_seen(state, device_id) do
    now = System.system_time(:second)

    update_in(state, [:devices, device_id], fn
      nil -> nil
      device -> %{device | last_seen: now}
    end)
  end

  # The corrected private function
  defp update_roster_last_seen(state, target_eid) do
    now = System.system_time(:second)

    # Changed :roaster -> :roster to match your state map
    update_in(state.roster, fn roster_map ->
      case Map.get(roster_map, target_eid) do
        nil ->
          roster_map
        user_meta ->
          Map.put(roster_map, target_eid, %{user_meta | last_seen: now})
      end
    end)
  end

end
