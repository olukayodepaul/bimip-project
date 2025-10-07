defmodule Bimip.Device.Client do
  # bimip
  use GenServer
  alias Bimip.Registry
  alias Settings.AdaptiveNetwork
  alias Util.Network.AdaptivePingPong
  alias App.RegistryHub
  alias ThrowErrorScheme
  alias ThrowLogouResponseSchema
  alias ThrowPingPongSchema

  # Start GenServer for device session
  def start_link({_eid, device_id, _ws_pid} = state) do
    GenServer.start_link(__MODULE__, state, name: Registry.via_registry(device_id))
  end

  @impl true
  def init({eid, device_id, ws_pid}) do
    RegistryHub.register_device_in_server({device_id, eid, ws_pid}) # pass
    AdaptivePingPong.schedule_ping(device_id)

    {:ok,
      %{
        missed_pongs: 0,
        pong_counter: 0,
        timer: DateTime.utc_now(),
        eid: eid,
        device_id: device_id,
        ws_pid: ws_pid,
        last_rtt: nil,
        max_missed_pongs_adaptive: AdaptiveNetwork.initial_max_missed_pings(),
        last_send_ping: nil,
        last_state_change: DateTime.utc_now(),

        # nested device state (replacement for ETS)
        device_state: %{
          device_status: "ONLINE",  # pick one as default
          last_change_at: nil,
          last_seen: nil,
          last_activity: DateTime.utc_now()
        }
      }}
  end

  def handle_cast({:receive_awareness_from_server, {_eid, _device_id, binary}}, %{ws_pid: ws_pid} = state) do
    send(ws_pid, {:binary, binary})
    {:noreply, state}
  end

  # Handle ping/pong
  @impl true
  def handle_info({:send_ping, interval}, state) do
    AdaptivePingPong.handle_ping(%{state | last_rtt: interval})
  end

  @impl true
  def handle_cast({:received_pong, {device_id, receive_time}}, state) do 
    AdaptivePingPong.pongs_received(device_id, receive_time, state)
  end

  def handle_cast({:send_terminate_signal_to_client, {device_id, eid}}, state) do
    RegistryHub.send_terminate_signal_to_server({device_id, eid})
    {:stop, :normal, state}
  end

  def handle_cast({:logout, _eid, _device_id, data}, %{ws_pid: ws_pid, eid: eid, device_id: device_id} = state) do
    msg = Bimip.MessageScheme.decode(data)
    case msg.payload do
      {:logout, %Bimip.Logout{type: 1, to: %{eid: ^eid, connection_resource_id: ^device_id}} = logout_msg} ->
        is_logout = ThrowLogouResponseSchema.logout(eid, device_id)
        send(ws_pid, {:binary, is_logout})
        send(ws_pid, :terminate_socket)
        {:noreply, state}

      {:logout, _} ->
        error_msg = ThrowErrorScheme.error(401, "Invalid User Session Credential", 10)
        send(ws_pid, {:binary, error_msg})
        send(ws_pid, :terminate_socket)
        {:noreply, state}

      _ ->
        error_msg = ThrowErrorScheme.error(401, "Invalid Request", 10)
        send(ws_pid, {:binary, error_msg})
        send(ws_pid, :terminate_socket)
        {:noreply, state}
    end
  end

  def handle_cast({:ping_pong, data}, %{ws_pid: ws_pid, eid: eid, device_id: device_id} = state) do
    msg = Bimip.MessageScheme.decode(data)

    case msg.payload do
      {:ping_pong, %Bimip.PingPong{type: 1, to: %{eid: ^eid, connection_resource_id: ^device_id}} = ping_pong_msg} ->
        handle_ping_request(ping_pong_msg, state)

      {:ping_pong, _} ->
        reply_and_close(ws_pid, ThrowErrorScheme.error(401, "Invalid User Session Credential", 3))
        {:noreply, state}

      _ ->
        reply_and_close(ws_pid, ThrowErrorScheme.error(401, "Invalid Request", 3))
        {:noreply, state}
    end
  end

  defp reply_and_close(ws_pid, binary) do
    send(ws_pid, {:binary, binary})
  end

  defp handle_ping_request(%Bimip.PingPong{resource: 1, ping_time: ping_time}, %{ws_pid: ws_pid, eid: eid, device_id: device_id} = state) do
    case RegistryHub.request_cross_server_online_state(eid) do
      :ok ->
        pong = ThrowPingPongSchema.same(eid, device_id, ping_time)
        send(ws_pid, {:binary, pong})
        {:noreply, state}

      :error ->
        reply_and_close(ws_pid, ThrowErrorScheme.error(404, "Service Unavailable", 3))
        {:noreply, state}
    end
  end

end

# Bimip.Device.Client.get_state("aaaaa2")