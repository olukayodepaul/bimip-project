defmodule Bimip.SignalServer do

  use GenServer
  require Logger
  @partition 1
  @message_route_id 6
  alias Supervisor.{Registry, Client}


  # ----------------------
  # Start
  # ----------------------
  def start_link(%{eid: eid} = state) do
    GenServer.start_link(__MODULE__, state, name: Registry.via_monitor_registry(eid))
  end

  @impl true
  def init(%{eid: eid, device_id: device_id, ws_pid: ws_pid, exp: exp, uupid: uupid, subc: subc}) do

    subscribers = subc |> BimipSubscribers.Handler.extract_eids()

    initial_state = %{
      eid: eid,
      current_timer: nil,
      force_stale: System.system_time(:second),
      devices: %{},
      sub:  subscribers |> MapSet.new()
    }
    Queue.QueueLogImpl.system_recovery(eid, @partition)
    Bimip.Broker.Server.user_topic(eid)
    Bimip.Broker.Server.subscribe_to_users(subscribers)
    {:ok, initial_state, {:continue, {:start_device, {eid, device_id, exp, ws_pid, uupid, subc}}}}
  end


  # ----------------------
  # Device management
  # ----------------------
  @impl true
  def handle_cast({:start_device, {eid, device_id, exp, ws_pid, uupid, subc}}, state) do
    case Client.start_session({eid, device_id, exp, ws_pid, uupid}) do
      {:ok, _pid} ->
        now = System.system_time(:second)

        device_info = %{
          ws_pid: ws_pid,
          device_id: device_id,
          eid: eid,
          uupid: uupid,
          last_seen: now,
          token_expiration: exp
        }

        # new_sub_set = subc |> BimipSubscribers.Handler.extract_eids() |> MapSet.new()

        new_state =
          state
          # |> Map.put(:sub, new_sub_set) # Replaces the old subscriber set
          |> update_in([:devices, device_id], fn
            nil ->
              device_info
            existing ->
              %{existing |
                ws_pid: ws_pid,
                last_seen: now,
                token_expiration: exp
              }
          end)

        {:noreply, new_state}

      {:error, reason} ->
        Logger.error("Failed to start device #{device_id} for #{eid}: #{inspect(reason)}")
        {:noreply, state}
    end
  end

  @impl true
  def handle_continue({:start_device, {eid, device_id, exp, ws_pid, uupid, subc}}, state) do
    handle_cast({:start_device, {eid, device_id, exp, ws_pid, uupid, subc}}, state)
  end

  def handle_cast({:message, %{
    message: message,
    device_id: device_id,
    uupid: _uupid } = message_builder}, state
    ) do

    case subscribers_validation(message.to.eid) do
      {:ok, :success} ->
         Task.Supervisor.start_child(Message.TaskSupervisor, fn ->
          t1 = Task.async(fn -> Message.Broker.sender(message_builder, state.devices) end)
          t2 = Task.async(fn -> Message.Broker.recv(message_builder) end)

          Task.await(t1)
          Task.await(t2)
        end)
      {:error, :failed} ->
        reason = "Field 'to.eid' → #{message.to.eid} Invalid subscriber 500"
        ThrowProtocolErrorSchema.build(@message_route_id, reason, Until.UniPosTime.response_time())
        |> then(&Route.Connect.outbouce(device_id, &1))
    end
    {:noreply, state}
  end

  #subscribers_validation is next and asfter complating the ping
  defp subscribers_validation(subscriber_eid) do
    validate = 1
    if validate == 1 do
      {:ok, :success}
    else
      {:error, :failed}
    end
  end

  @impl true
  def handle_cast({:message_transmiter, message_builder}, state) do
    Device.Transmission.emit(state.eid, 0, state.devices, message_builder)
    {:noreply, state}
  end

  @impl true
  def handle_cast({:compose, binary}, state) do
    Device.Transmission.emit(state.eid, 0, state.devices, binary)
    {:noreply, state}
  end

  @impl true
  def handle_cast({:offset_commit, data}, state) do
    Commit.Offset.offset_commit(data)
    {:noreply, state}
  end

  @impl true
  def handle_cast({:ping, device_id}, state) do
    now = System.system_time(:second)
    case Map.fetch(state.devices, device_id) do
    {:ok, device} ->

      updated_device = %{device | last_seen: now}
      updated_devices = Map.put(state.devices, device_id, updated_device)

      {:noreply, %{state | devices: updated_devices}}
    :error ->
      {:noreply, state}
    end
  end

  def handle_cast({:awareness, data}, state) do
    {:noreply, state}
  end

  def handle_cast({:broadcast, bin}, state) do
    Bimip.Broker.Server.broadcast_to_user(state.eid, {:presence_update, bin})
    {:noreply, state}
  end

  def handle_info({:presence_update, bin}, state) do
    Device.Transmission.emit_broadcast(state.devices, bin)
    {:noreply, state}
  end


end
