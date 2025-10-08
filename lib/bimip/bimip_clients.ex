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
  alias Bimip.Validators.PingPongValidator
  alias Bimip.PingPong

  # Start GenServer for device session
  def start_link({_eid, device_id, _exp, _ws_pid} = state) do
    GenServer.start_link(__MODULE__, state, name: Registry.via_registry(device_id))
  end

  @impl true
  def init({eid, device_id, exp, ws_pid}) do
    RegistryHub.register_device_in_server({device_id, eid, ws_pid}) # pass
    AdaptivePingPong.schedule_ping(device_id)

    {:ok,
      %{
        missed_pongs: 0,
        pong_counter: 0,
        timer: DateTime.utc_now(),
        eid: eid,
        device_id: device_id,
        exp_time: exp,
        token_state: :active,
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
      {:logout, %Bimip.Logout{} = logout_msg} ->
        # Step 1: Validate the Logout message structure
        case Bimip.Validators.LogoutValidator.validate_logout(logout_msg) do
          :ok ->
            # Step 2: Ensure the logout is coming from the same session
            if logout_msg.to.eid == eid and logout_msg.to.connection_resource_id == device_id do
              is_logout = ThrowLogouResponseSchema.logout(eid, device_id)
              send(ws_pid, {:binary, is_logout})
              send(ws_pid, :terminate_socket)
              {:noreply, state}
            else
              details = %{description: "Invalid User Session Credential", field: "to"}
              error_msg = ThrowErrorScheme.error(401, details, 10)
              send(ws_pid, {:binary, error_msg})
              send(ws_pid, :terminate_socket)
              {:noreply, state}
            end

          {:error, err} ->
            # Step 3: Send structured protobuf error back to client
            details = %{description: err.description, field: err.field}
            error_msg = ThrowErrorScheme.error(err.code, details, 10)
            send(ws_pid, {:binary, error_msg})
            {:noreply, state}
        end

      _ ->
        # Catch-all for invalid payload type
        details = %{description: "Invalid Request", field: "payload"}
        error_msg = ThrowErrorScheme.error(401, details, 10)
        send(ws_pid, {:binary, error_msg})
        send(ws_pid, :terminate_socket)
        {:noreply, state}
    end
  end


  def handle_cast({:ping_pong, eid, device_id, data}, %{ws_pid: ws_pid, eid: eid, device_id: device_id} = state) do
    msg = Bimip.MessageScheme.decode(data)

    case msg.payload do
      {:ping_pong, %PingPong{} = ping_pong_msg} ->
        case PingPongValidator.validate_pingpong(ping_pong_msg) do
          {:ok, valid_msg} ->
            handle_valid_pingpong(valid_msg, state)

          {:error, err} ->

            details = %{
              description: err.description,
              field: err.field
            }

            reply_client(ws_pid, ThrowErrorScheme.error(err.code, details, 3))
            {:noreply, state}
        end

      _ ->
        reply_client(ws_pid, ThrowErrorScheme.error(100, %{description: "Invalid Request. Expected valid ping_pong payload"}, 3))
        {:noreply, state}
    end
  end

  defp handle_valid_pingpong(%PingPong{type: 1} = ping_pong, %{ws_pid: ws_pid, eid: eid, device_id: device_id} = state) do
    case ping_pong.resource do
      1 ->
        pong = ThrowPingPongSchema.same(eid, device_id, ping_pong.ping_time)
        reply_client(ws_pid, pong)
        {:noreply, state}

      2 ->
        case RegistryHub.request_cross_server_online_state(ping_pong.to.eid) do
          
          :ok ->

            pong = ThrowPingPongSchema.others(ping_pong.from.eid, ping_pong.from.connection_resource_id, ping_pong.to.eid, ping_pong.to.connection_resource_id, ping_pong.ping_time)
            reply_client(ws_pid, pong)
            {:noreply, state}

          :error ->
            reply_client(ws_pid, ThrowErrorScheme.error(600, %{description: "Target device disconnected"}, 3))
            {:noreply, state}
            
        end

      _ ->
        reply_client(ws_pid, ThrowErrorScheme.error(100, %{description: "Invalid resource value"}, 3))
        {:noreply, state}
    end
  end

  defp handle_valid_pingpong(%PingPong{type: 2} = _pong_msg, %{ws_pid: ws_pid} = state) do
    err = %{
      code: 400, 
      field: "type",
      description: "Client cannot send PONG; only PING is allowed"
    }

    details = %{
      description: err.description,
      field: err.field
    }

    reply_client(ws_pid, ThrowErrorScheme.error(err.code, details, 3))

    {:noreply, state}
  end

  defp reply_client(ws_pid, binary) do
    send(ws_pid, {:binary, binary})
  end

end

# Bimip.Device.Client.get_state("aaaaa2")