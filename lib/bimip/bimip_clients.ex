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
    
    AdaptivePingPong.schedule_ping(device_id)

    {:ok,
      %{
        missed_pongs: 0,
        pong_counter: 0,
        timer: DateTime.utc_now(),
        eid: eid,
        device_id: device_id,
        exp_time: exp, #token expiration time
        token_state: :active, # token state...
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

  def handle_cast(
        {:route_awareness, _eid, _device_id, data},
        %{ws_pid: ws_pid, eid: eid, device_id: device_id} = state
      ) do

    msg = Bimip.MessageScheme.decode(data)

    case msg.payload do
      {:awareness, %Bimip.Awareness{} = awareness_msg} ->
        # Validate the Awareness message
        case Bimip.Validators.AwarenessValidator.validate_awareness(awareness_msg) do
          :ok ->

            awareness_type =
              case awareness_msg.status do
                s when s in 1..5 -> :user  # User Awareness → broadcast to subscribers
                s when s in 6..8 -> :system  # System Awareness → per-to-per
              end

            encoded_message = ThrowAwarenessSchema.success(
              awareness_msg.from.eid,
              awareness_msg.from.connection_resource_id,
              awareness_msg.to.eid,
              awareness_msg.to.connection_resource_id,
              awareness_msg.status,
              awareness_msg.location_sharing,
              awareness_msg.latitude,
              awareness_msg.longitude,
              awareness_msg.ttl,
              awareness_msg.details
            )
            
            RegistryHub.route_awareness_to_server(
              awareness_msg.from.eid, 
              awareness_msg.to.eid, 
              awareness_type,
              encoded_message
            )
            
            {:noreply,
              %{
                state
                | device_state: %{
                    state.device_state
                    | last_seen: DateTime.utc_now(),
                      last_activity: DateTime.utc_now(),
                      last_change_at: DateTime.utc_now()
                  }
              }
            }

          {:error, err} ->
  
            reason = "Field '#{err.field}' → #{err.description}"

            error_binary = ThrowAwarenessSchema.error(
              awareness_msg.from.eid,
              awareness_msg.from.connection_resource_id,
              reason
            )

            send(ws_pid, {:binary, error_binary})
            {:noreply, state}

        end

      _ ->

        reason = "Invalid payload: expected Awareness message"
        error_binary = ThrowAwarenessSchema.error(eid, device_id, reason)
        send(ws_pid, {:binary, error_binary})
        {:noreply, state}
        
    end
  end

  def handle_cast({:logout, _eid, _device_id, data}, %{ws_pid: ws_pid, eid: eid, device_id: device_id} = state) do
    msg = Bimip.MessageScheme.decode(data)

    case msg.payload do
      {:logout, %Bimip.Logout{} = logout_msg} ->
        case Bimip.Validators.LogoutValidator.validate_logout(logout_msg, eid, device_id) do
          :ok ->
            # Check if request is truly from this session
            if logout_msg.to.eid == eid and logout_msg.to.connection_resource_id == device_id do
              success = ThrowLogouResponseSchema.logout(eid, device_id, 2, 1)
              send(ws_pid, {:binary, success})
              send(ws_pid, :terminate_socket)
            else
              fail = ThrowLogouResponseSchema.logout(eid, device_id, 3, 2, "Invalid user session credentials")
              send(ws_pid, {:binary, fail})
              send(ws_pid, :terminate_socket)
            end

          {:error, err} ->
            reason = "Field '#{err.field}' → #{err.description}"
            fail = ThrowLogouResponseSchema.logout(eid, device_id, 3, 2, reason)
            send(ws_pid, {:binary, fail})
        end

        {:noreply, state}

      _ ->
        # Invalid stanza or wrong payload type
        invalid = ThrowLogouResponseSchema.logout(eid, device_id, 3, 2, "Invalid logout stanza")
        send(ws_pid, {:binary, invalid})
        {:noreply, state}
    end
  end

  def handle_cast({:ping_pong, eid, device_id, data}, %{ws_pid: ws_pid, eid: eid, device_id: device_id} = state) do
    msg = Bimip.MessageScheme.decode(data)

    case msg.payload do
      {:ping_pong, %PingPong{} = ping_pong_msg} ->
        case PingPongValidator.validate_pingpong(ping_pong_msg, eid, device_id) do
          :ok ->
            handle_valid_pingpong(ping_pong_msg, state)

          {:error, err} ->
            fail = ThrowPingPongSchema.error(eid, device_id, err.description)
            reply_client(ws_pid, fail)
            {:noreply, state}
        end

      _ ->
        fail = ThrowPingPongSchema.error(eid, device_id, "Invalid Request. Expected valid ping_pong payload")
        reply_client(ws_pid, fail)
        {:noreply, state}
    end
  end


  defp handle_valid_pingpong(%PingPong{type: 1} = ping_pong, %{ws_pid: ws_pid, eid: eid, device_id: device_id} = state) do
    #update  last_activity, 
    case ping_pong.resource do
      1 ->
        pong = ThrowPingPongSchema.same(eid, device_id, ping_pong.ping_time)
        reply_client(ws_pid, pong)
        {:noreply, state}

      2 ->
        case RegistryHub.request_cross_server_online_state(ping_pong.to.eid) do
          :ok ->
            pong =
              ThrowPingPongSchema.others(
                ping_pong.from.eid,
                ping_pong.from.connection_resource_id,
                ping_pong.to.eid,
                ping_pong.to.connection_resource_id,
                ping_pong.ping_time
              )

            reply_client(ws_pid, pong)
            {:noreply, state}

          :error ->
            fail = ThrowPingPongSchema.error(eid, device_id, "Target device disconnected")
            reply_client(ws_pid, fail)
            {:noreply, state}
        end

      _ ->
        fail = ThrowPingPongSchema.error(eid, device_id, "Invalid resource value")
        reply_client(ws_pid, fail)
        {:noreply, state}
    end
  end


  defp handle_valid_pingpong(%PingPong{type: 2}, %{ws_pid: ws_pid, eid: eid, device_id: device_id} = state) do
    fail = ThrowPingPongSchema.error(eid, device_id, "Client cannot send PONG; only PING is allowed")
    reply_client(ws_pid, fail)
    {:noreply, state}
  end

  defp reply_client(ws_pid, binary) do
    send(ws_pid, {:binary, binary})
  end

end

# Bimip.Device.Client.get_state("aaaaa2")

