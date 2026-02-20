defmodule Bimip.SignalServer do
  use GenServer
  require Logger





  #old alias
  alias Supervisor.{Registry, Client}
  alias Route.SignalCommunication
  alias Chat.{SendMessage, ReceivedSignal}
  # refactoring

  alias Storage.DeviceStorage
  alias Storage.Registration
  alias Bimip.Broker
  alias Settings.ServerState
  alias Route.AwarenessFanOut
  alias ThrowAwarenessSchema
  alias Util.StatusMapper
  alias BimipLog
  alias BimipRPCClient




  @stale_threshold_seconds ServerState.stale_threshold_seconds()
  # ----------------------
  # Start
  # ----------------------
  def start_link(%{eid: eid} = state) do
    GenServer.start_link(__MODULE__, state, name: Registry.via_monitor_registry(eid))
  end

  # ----------------------
  # Initialization
  # ----------------------
  @impl true
  def init(%{eid: eid, device_id: device_id, ws_pid: ws_pid, exp: exp, uupid: uupid}) do
    # Initial state with empty devices map
    initial_state = %{
      eid: eid,
      current_timer: nil,
      force_stale: DateTime.utc_now(),
      devices: %{}
    }

    {:ok, initial_state, {:continue, {:start_device, {eid, device_id, exp, ws_pid, uupid}}}}
  end

  # ----------------------
  # Device management
  # ----------------------
  @impl true
  def handle_cast({:start_device, {eid, device_id, exp, ws_pid, uupid}}, state) do
    case Client.start_session({eid, device_id, exp, ws_pid, uupid}) do
      {:ok, _pid} ->
        now = DateTime.utc_now()

        device_info = %{
          ws_pid: ws_pid,
          device_id: device_id,
          eid: eid,
          uupid: uupid,
          last_seen: now,
          token_expiration: exp
        }

        new_state =
          update_in(state, [:devices, device_id], fn
            nil ->
              device_info
            existing ->
              %{
                existing
                | ws_pid: ws_pid,
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

  # ----------------------
  # Continue callback to handle init device startup
  # ----------------------
  @impl true
  def handle_continue({:start_device, {eid, device_id, exp, ws_pid, uupid}}, state) do
    handle_cast({:start_device, {eid, device_id, exp, ws_pid, uupid}}, state)
  end

  def handle_cast({:message, message_builder}, state) do
    Task.Supervisor.start_child(Message.TaskSupervisor, fn ->
      t1 = Task.async(fn -> Message.Broker.sender(message_builder) end)
      t2 = Task.async(fn -> Message.Broker.recv(message_builder) end)

      Task.await(t1)
      Task.await(t2)
    end)

    {:noreply, state}
  end

  @impl true
  def handle_cast({:message_transmiter, message_builder}, state) do
    IO.inspect(message_builder)
    {:noreply, state}
  end


















  # ----------------------
  # Client pong handler
  # ----------------------
  # Note when working on ping pong, verify is this is a system ping pong. network ping pong is not allow on server
  # Only client server ping pong is allow on the server. client genserver should handle network ping pong
  # only send message to server only when want to terminate
  @impl true
  def handle_cast({:client_send_pong, {eid, device_id, status}}, %{force_stale: force_stale} = state) do
    # now = DateTime.utc_now()
    # DeviceStorage.update_device_status(device_id, eid, "PONG", StatusMapper.status_name(status))

    # case Storage.DeviceStateChange.track_state_change(eid) do
    #   {:changed, _user_status, _online_devices} ->
    #     {:noreply, %{state | force_stale: now}}
    #   {:unchanged, _user_status, _online_devices} ->
    #     idle_too_long? = DateTime.diff(now, force_stale) >= @stale_threshold_seconds
    #     if idle_too_long?, do: {:noreply, %{state | force_stale: now}}, else: {:noreply, state}
    # end

    {:noreply, state}
  end

  def handle_cast({:route_ping_pong, eid, device_id}, %{visibility: visibility} = state) do
    DeviceStorage.update_device_status(device_id, eid, "PING_PONG", StatusMapper.status_name(1))
    Broker.group(eid, ThrowAwarenessSchema.success(eid, device_id, "", "", 6), visibility)
    {:noreply, state}
  end

  # -------------------------------------
  # Catch-all for unexpected messages
  # -------------------------------------
  @impl true
  def handle_info(msg, state) do
    Logger.warning("Unhandled message received in Master GenServer: #{inspect(msg)}")
    {:noreply, state}
  end

  @impl true
  def handle_cast({:fetch_batch_notification, eid, device_id}, state) do
    # case BimipLog.fetch(eid, device_id, 2, 10) do
    #   {:ok, %{messages: messages}} -> Enum.each(messages, &IO.inspect(&1))
    #   {:error, reason} -> Logger.error("[FETCH] failed for eid=#{eid}: #{inspect(reason)}")
    # end

    {:noreply, state}
  end


  # ----------------------
  # Termination handling
  # ----------------------
  @impl true
  def handle_cast({:send_terminate_signal_to_server, %{device_id: device_id, eid: eid}}, %{current_timer: current_timer} = state) do
    # DeviceStorage.delete_device(device_id, eid)
    # if Storage.DeviceStorage.remaining_active_devices?(eid) do
    #   DeviceStorage.cancel_termination_if_any_device_are_online(current_timer)
    #   {:noreply, state}
    # else
    #   DeviceStorage.schedule_termination_if_all_offline(state)
    #   {:noreply, state}
    # end
    {:noreply, state}
  end


  # ----------------------
  # Fetch messages
  # ----------------------
  @impl true
  def handle_cast({:fetch_batch_chat, eid, device_id}, state) do
    # case BimipLog.fetch(eid, device_id, 1, 10) do
    #   {:ok, %{messages: messages}} -> Enum.each(messages, &IO.inspect(&1))
    #   {:error, reason} -> Logger.error("[FETCH] failed for eid=#{eid}: #{inspect(reason)}")
    # end

    {:noreply, state}
  end






  # # -------------------------------
  # # Signal
  # # -------------------------------
  # @impl true
  # def handle_cast({:signal_to_server, payload}, state) do
  #   {:noreply, state}
  # end



  # def handle_cast({:signal_deliver_ack_server, payload}, state) do

  #   %Bimip.BatchedOffset{
  #     owners: %Bimip.OWNERS {
  #     from: _from,
  #     to: _to
  #     }
  #   } = List.first(payload)

  #   {:noreply, state}

  # end


  @impl true
  def handle_cast({:signal_to_server_ack, payload}, %{eid: eid} = state) do
    # IO.inspect({payload, eid})
    {:noreply, state}
  end



end
