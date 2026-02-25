defmodule Bimip.SignalClient do
  # bimip
  use GenServer
  @message_route_id 6
  @compose_route_id 4
  @commit_offset_route_id 7
  @ping_route_id 3
  alias Bimip.{MessageScheme}



  alias Supervisor.{Registry}
  alias Settings.AdaptiveNetwork
  alias Util.Network.AdaptivePingPong
  alias Route.Connect
  alias ThrowErrorScheme
  alias ThrowLogouResponseSchema
  alias ThrowPingPongSchema
  alias Bimip.Validators.PingPongValidator
  alias Bimip.PingPong



  # Start GenServer for device session
  def start_link({_eid, device_id, _exp, _ws_pid, _uupid} = state) do
    GenServer.start_link(__MODULE__, state, name: Registry.via_registry(device_id))
  end

  def init({eid, device_id, exp, ws_pid, uupid}) do
    now = DateTime.utc_now()

    # 1. Schedule the first check
    Util.Network.AdaptivePingPong.schedule_ping(device_id)

    # 2. Return the COMPLETE state map
    {:ok,
      %{
        # Basic Info
        eid: eid,
        device_id: device_id,
        uupid: uupid,
        ws_pid: ws_pid,
        exp: exp,

        # REQUIRED for AdaptivePingPong
        timer: now,                         # Tracks last ping attempt
        last_seen: now,                      # Tracks last activity
        last_rtt: nil,                       # Network speed
        missed_pongs: 0,                     # Health check
        pong_counter: 0,                     # Status refresh counter
        last_state_change: now,              # For Registry updates
        last_reported_seen: nil,             # For external presence
        presence_report_interval: 60_000,    # 60 seconds
        max_missed_pongs_adaptive: 3         # Initial limit
      }
    }
  end




  def handle_cast({:send_terminate_signal_to_client, {device_id, eid}}, state) do
    # RegistryHub.send_terminate_signal_to_server({device_id, eid})
    {:stop, :normal, state}
  end

  def handle_cast(
        {:route_awareness, _eid, _device_id, data},
        %{ws_pid: ws_pid, eid: eid, device_id: device_id} = state
      ) do

    # msg = Bimip.MessageScheme.decode(data)

    # case msg.payload do
    #   {:awareness, %Bimip.Awareness{} = awareness_msg} ->
    #     # Validate the Awareness message
    #     case Bimip.Validators.AwarenessValidator.validate_awareness(awareness_msg) do
    #       :ok ->

    #         encoded_message = ThrowAwarenessSchema.success(
    #           awareness_msg.from.eid,
    #           awareness_msg.from.connection_resource_id,
    #           awareness_msg.to.eid,
    #           awareness_msg.to.connection_resource_id,
    #           awareness_msg.status,
    #           awareness_msg.location_sharing,
    #           awareness_msg.latitude,
    #           awareness_msg.longitude,
    #           awareness_msg.ttl,
    #           awareness_msg.details,
    #           awareness_msg.id
    #         )

    #         RegistryHub.route_awareness_to_server(
    #           awareness_msg.from.eid,
    #           awareness_msg.from.connection_resource_id,
    #           awareness_msg.to.eid,
    #           awareness_msg.to.connection_resource_id,
    #           awareness_msg.status,
    #           encoded_message
    #         )

    #         {:noreply,
    #           %{
    #             state
    #             | device_state: %{
    #                 state.device_state
    #                 | last_seen: DateTime.utc_now(),
    #                   last_activity: DateTime.utc_now(),
    #                   last_change_at: DateTime.utc_now()
    #               }
    #           }
    #         }

    #       {:error, err} ->

    #         reason = "Field '#{err.field}' → #{err.description}"

    #         error_binary = ThrowAwarenessSchema.error(
    #           awareness_msg.from.eid,
    #           awareness_msg.from.connection_resource_id,
    #           reason
    #         )

    #         send(ws_pid, {:binary, error_binary})
    #         {:noreply, state}

    #     end

    #   _ ->

    #     reason = "Invalid payload: expected Awareness message"
    #     error_binary = ThrowAwarenessSchema.error(eid, device_id, reason)
    #     send(ws_pid, {:binary, error_binary})
    #     {:noreply, state}

    # end
    {:noreply, state}
  end

  def handle_cast({:logout, _eid, _device_id, data}, %{ws_pid: ws_pid, eid: eid, device_id: device_id} = state) do
    msg = Bimip.MessageScheme.decode(data)

    # case msg.payload do
    #   {:logout, %Bimip.Logout{} = logout_msg} ->
    #     case Bimip.Validators.LogoutValidator.validate_logout(logout_msg, eid, device_id) do
    #       :ok ->
    #         # Check if request is truly from this session
    #         if logout_msg.to.eid == eid and logout_msg.to.connection_resource_id == device_id do
    #           success = ThrowLogouResponseSchema.logout(eid, device_id, 2, 1)
    #           send(ws_pid, {:binary, success})
    #           send(ws_pid, :terminate_socket)
    #         else
    #           fail = ThrowLogouResponseSchema.logout(eid, device_id, 3, 2, "Invalid user session credentials")
    #           send(ws_pid, {:binary, fail})
    #           send(ws_pid, :terminate_socket)
    #         end

    #       {:error, err} ->
    #         reason = "Field '#{err.field}' → #{err.description}"
    #         fail = ThrowLogouResponseSchema.logout(eid, device_id, 3, 2, reason)
    #         send(ws_pid, {:binary, fail})
    #     end

    #     {:noreply, state}

    #   _ ->
    #     # Invalid stanza or wrong payload type
    #     invalid = ThrowLogouResponseSchema.logout(eid, device_id, 3, 2, "Invalid logout stanza")
    #     send(ws_pid, {:binary, invalid})
    #     {:noreply, state}
    # end
     {:noreply, state}
  end














    def handle_cast(
      {:ping_pong, _eid, _device_id, data},
      %{ws_pid: ws_pid, eid: eid, device_id: device_id} = state
    ) do

    # msg = Bimip.MessageScheme.decode(data)

    # case msg.payload do
    #   {:ping_pong, %Bimip.PingPong{} = pingpong_msg} ->
    #     # ✅ Validate PingPong message
    #     case Bimip.Validators.PingPongValidator.validate_pingpong(pingpong_msg, eid, device_id) do
    #       :ok ->

    #         pong = ThrowPingPongSchema.success(
    #           pingpong_msg.from.eid,
    #           pingpong_msg.from.connection_resource_id,
    #           pingpong_msg.id,
    #           2
    #         )

    #         send(ws_pid, {:binary, pong})

    #         RegistryHub.route_ping_pong_to_server(
    #           pingpong_msg.from.eid,
    #           pingpong_msg.from.connection_resource_id
    #         )

    #         {:noreply,
    #           %{
    #             state
    #             | device_state: %{
    #                 state.device_state
    #                 | last_seen: DateTime.utc_now(),
    #                   last_activity: DateTime.utc_now(),
    #                   last_change_at: DateTime.utc_now()
    #               }
    #           }
    #         }

    #       {:error, err} ->

    #         reason = "Field '#{err.field}' → #{err.description}"

    #         error_binary = ThrowPingPongSchema.error(
    #           pingpong_msg.from.eid,
    #           device_id,
    #           pingpong_msg.id,
    #           reason
    #         )

    #         send(ws_pid, {:binary, error_binary})
    #         {:noreply, state}
    #     end

    #   _ ->
    #     reason = "Invalid payload: expected PingPong message"
    #     error_binary = ThrowPingPongSchema.error(eid, device_id, 0, reason)
    #     send(ws_pid, {:binary, error_binary})
    #     {:noreply, state}
    # end
  end


  # Handle ping/pong
  @impl true
  def handle_info({:send_ping, interval}, state) do
    AdaptivePingPong.handle_ping(%{state | last_rtt: interval})
  end

  @impl true
  def handle_cast({:pong, receive_time}, state) do
    AdaptivePingPong.pongs_received(state.device_id, receive_time, state)
  end

  def handle_cast({:ping,  data},   %{device_id: device_id, eid: eid, uupid: uupid, ws_pid: ws_pid} = state) do
    bim = Bimip.MessageScheme.decode(data)
    case bim.payload do
      {:ping, %Bimip.Ping{} = ping} ->
        case Bimip.Validators.PingValidator.validate(ping, eid) do
          :ok ->

          %Bimip.MessageScheme{
            route_id: @ping_route_id,
            payload: {:ping, Map.put(ping, :type, 2)}
          }
          |> Bimip.MessageScheme.encode()
          |> then(&socket_outbound(ws_pid, &1))


          {:error, err} ->

            reason = "Field '#{err.field}' → #{err.description} #{err.code}"
            throws = ThrowProtocolErrorSchema.build(@ping_route_id, reason,Until.UniPosTime.response_time())
            socket_outbound(ws_pid, throws)
        end
        {:noreply, mark_active(state)}
      _ ->
        reason = "Unexpected payload received"
        throws = ThrowProtocolErrorSchema.build(@ping_route_id, reason, Until.UniPosTime.response_time())
        socket_outbound(ws_pid, throws)
        {:noreply, active_last_see(state)}
      end
  end

  def handle_cast({:native_pong_received, receive_time}, state) do
     {:noreply, Util.Network.AdaptivePingPong.pongs_received(state.device_id, receive_time, state)}
  end

  def handle_cast({:offset_commit,  data}, %{device_id: device_id, eid: eid, uupid: uupid, ws_pid: ws_pid} = state) do
    bim = Bimip.MessageScheme.decode(data)
    case bim.payload do
      {:offset_commit, %Bimip.OffsetCommit{} = offset_commit} ->
        case Bimip.Validators.OffsetCommitValidator.validate(offset_commit, eid) do
          :ok ->

            %{
              offset_commit: bim,
              device_id: device_id,
              uupid: uupid
            }
            |> server_inbound(:eid, :offset_commit, eid)

          {:error, err} ->
            reason = "Field '#{err.field}' → #{err.description} #{err.code}"
            throws = ThrowProtocolErrorSchema.build(@commit_offset_route_id, reason,Until.UniPosTime.response_time())
            socket_outbound(ws_pid, throws)
        end
        {:noreply, active_last_see(state)}
      _ ->
        reason = "Unexpected payload received"
        throws = ThrowProtocolErrorSchema.build(@commit_offset_route_id, reason, Until.UniPosTime.response_time())
        socket_outbound(ws_pid, throws)
        {:noreply, active_last_see(state)}
      end
  end

  def handle_cast({:compose,  data},   %{eid: eid, ws_pid: ws_pid} = state) do
    bim = Bimip.MessageScheme.decode(data)
    case bim.payload do
      {:compose, %Bimip.Compose{} = compose} ->
        case Bimip.Validators.ComposeValidator.validate(compose, eid) do
          :ok ->

            data
            |> server_inbound(:eid, :compose, compose.to.eid)

          :drop
            :noop
        end
        {:noreply, active_last_see(state)}
      _ ->
        {:noreply, active_last_see(state)}
      end
  end

  def handle_cast({:message,  data}, %{device_id: device_id, eid: eid, uupid: uupid, ws_pid: ws_pid} = state) do
    msg = Bimip.MessageScheme.decode(data)
    case msg.payload do
      {:message, %Bimip.Message{} = message} ->
        case Bimip.Validators.MessageValidator.validate(message) do
          :ok ->
            %{
              message: message,
              device_id: device_id,
              uupid: uupid
            }
            |> server_inbound(:eid, :message, eid)

          {:error, err} ->

            reason = "Field '#{err.field}' → #{err.description} #{err.code}"
            throws = ThrowProtocolErrorSchema.build(@message_route_id, reason,Until.UniPosTime.response_time())
            socket_outbound(ws_pid, throws)

        end
        {:noreply, active_last_see(state)}
      _ ->

        reason = "Unexpected payload received"
        throws = ThrowProtocolErrorSchema.build(@message_route_id, reason, Until.UniPosTime.response_time())
        socket_outbound(ws_pid, throws)
        {:noreply, active_last_see(state)}

      end
  end

  defp socket_outbound(ws_pid, binary) do
    send(ws_pid, {:binary, binary})
  end

  defp server_inbound(payload, chanel, signal_to_server, eid) do
    {chanel, eid, signal_to_server, payload}
    |> Connect.client_server_inbound()
  end

  def handle_cast({:outbouce,  binary}, %{ws_pid: ws_pid} = state) do
    send(ws_pid, {:binary, binary})
    {:noreply, state}
  end

  defp active_last_see(state) do
    state
    |> Map.put(:last_seen, DateTime.utc_now())
    |> Map.put(:missed_pongs, 0)
  end

  defp mark_active(state) do
    state
    |> Map.put(:last_seen, DateTime.utc_now())
    |> Map.put(:missed_pongs, 0)
    |> maybe_report_to_external_service()
  end

  defp maybe_report_to_external_service(state) do
    now = DateTime.utc_now()

    should_report = is_nil(state.last_reported_seen) or
                    DateTime.diff(now, state.last_reported_seen, :millisecond) >= state.presence_report_interval
    if should_report do
      server_inbound(%{last_seen: DateTime.utc_now(), device_id: state.device_id}, :eid, :ping, state.eid)
      %{state | last_reported_seen: now}
    else
      state
    end
  end


end
