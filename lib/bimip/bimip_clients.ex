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
              awareness_msg.details,
              awareness_msg.id
            )
            
            RegistryHub.route_awareness_to_server(
              awareness_msg.from.eid, 
              awareness_msg.from.connection_resource_id,
              awareness_msg.to.eid, 
              awareness_msg.to.connection_resource_id,
              awareness_msg.status,
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

  def handle_cast(
      {:ping_pong, _eid, _device_id, data},
      %{ws_pid: ws_pid, eid: eid, device_id: device_id} = state
    ) do
  
    msg = Bimip.MessageScheme.decode(data)

    case msg.payload do
      {:ping_pong, %Bimip.PingPong{} = pingpong_msg} ->
        # ✅ Validate PingPong message
        case Bimip.Validators.PingPongValidator.validate_pingpong(pingpong_msg, eid, device_id) do
          :ok ->

            pong = ThrowPingPongSchema.success(
              pingpong_msg.from.eid,
              pingpong_msg.from.connection_resource_id,
              pingpong_msg.id,
              2
            )

            send(ws_pid, {:binary, pong})

            RegistryHub.route_ping_pong_to_server(
              pingpong_msg.from.eid,
              pingpong_msg.from.connection_resource_id
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

            error_binary = ThrowPingPongSchema.error(
              pingpong_msg.from.eid,
              device_id,
              pingpong_msg.id,
              reason
            )

            send(ws_pid, {:binary, error_binary})
            {:noreply, state}
        end

      _ ->
        reason = "Invalid payload: expected PingPong message"
        error_binary = ThrowPingPongSchema.error(eid, device_id, 0, reason)
        send(ws_pid, {:binary, error_binary})
        {:noreply, state}
    end
  end

  def handle_cast(
        {:client_awareness_visibility, _eid, _device_id, data},
        %{ws_pid: ws_pid, eid: eid, device_id: device_id} = state
      ) do

    msg = Bimip.MessageScheme.decode(data)

    case msg.payload do
      {:awareness_visibility, %Bimip.AwarenessVisibility{} = visibility_msg} ->
        # ✅ Validate the AwarenessVisibility message
        case Bimip.Validators.AwarenessVisibilityValidator.validate(visibility_msg, eid, device_id) do
          :ok ->

            post = %{
              id: visibility_msg.id,
              eid: visibility_msg.from.eid,
              device_id: visibility_msg.from.connection_resource_id,
              type: visibility_msg.type,
              timestamp: visibility_msg.timestamp
            }
            
            RegistryHub.route_awareness_visibility_to_server(post)

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

            error_binary = ThrowAwarenessVisibilitySchema.error(
              eid,
              device_id,
              visibility_msg.id,
              reason
            )

            send(ws_pid, {:binary, error_binary})
            {:noreply, state}
        end

      _ ->
        # ❌ Unexpected payload type
        reason = "Invalid payload: expected AwarenessVisibility message"
        error_binary = ThrowAwarenessVisibilitySchema.error(eid, device_id, 0, reason)
        send(ws_pid, {:binary, error_binary})
        {:noreply, state}
    end
  end


end

# Bimip.Device.Client.get_state("aaaaa2")

