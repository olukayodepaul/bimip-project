defmodule Bimip.SignalClient do
  # bimip
  use GenServer
  @message_route_id 6
  @compose_route_id 4
  @commit_offset_route_id 7
  @ping_route_id 3
  @wareness_id 3
  alias Bimip.{MessageScheme}
  alias Supervisor.{Registry}
  alias Util.Network.AdaptivePingPong
  alias Route.Connect


  # Start GenServer for device session
  def start_link({_eid, device_id, _exp, _ws_pid, _uupid} = state) do
    GenServer.start_link(__MODULE__, state, name: Registry.via_registry(device_id))
  end

  def init({eid, device_id, exp, ws_pid, uupid}) do

    now_mono = System.monotonic_time(:millisecond)
    Util.Network.AdaptivePingPong.schedule_next_ping(device_id, nil)

    {:ok,
      %{
        # Basic Info
        eid: eid,
        device_id: device_id,
        uupid: uupid,
        ws_pid: ws_pid,
        exp: exp,

        # REQUIRED for AdaptivePingPong
        last_seen: now_mono,
        last_ping_sent_at: nil,
        last_rtt: nil,
        missed_pongs: 0,
        last_reported_ms: 0
      }
    }
  end

  def handle_cast({:send_terminate_signal_to_client, {device_id, eid}}, state) do
    # RegistryHub.send_terminate_signal_to_server({device_id, eid})
    {:stop, :normal, state}
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

  def handle_info(:tick_ping, state) do
    AdaptivePingPong.handle_ping(state)
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
        {:noreply, AdaptivePingPong.mark_active(state)}
      _ ->
        reason = "Unexpected payload received"
        throws = ThrowProtocolErrorSchema.build(@ping_route_id, reason, Until.UniPosTime.response_time())
        socket_outbound(ws_pid, throws)
        {:noreply, AdaptivePingPong.mark_active(state)}
      end
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
        {:noreply, mark_active(state)}
      _ ->
        reason = "Unexpected payload received"
        throws = ThrowProtocolErrorSchema.build(@commit_offset_route_id, reason, Until.UniPosTime.response_time())
        socket_outbound(ws_pid, throws)
        {:noreply, mark_active(state)}
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
        {:noreply, mark_active(state)}
      _ ->
        {:noreply, mark_active(state)}
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
        {:noreply, mark_active(state)}
      _ ->

        reason = "Unexpected payload received"
        throws = ThrowProtocolErrorSchema.build(@message_route_id, reason, Until.UniPosTime.response_time())
        socket_outbound(ws_pid, throws)
        {:noreply, mark_active(state)}

      end
  end

  def handle_cast({:awareness,  data}, %{device_id: device_id, eid: eid, uupid: uupid, ws_pid: ws_pid} = state) do
    bim = Bimip.MessageScheme.decode(data)
    case bim.payload do
      {:awareness, %Bimip.Awareness{} = awareness} ->
        case Bimip.Validators.AwarenessValidator.validate(awareness, eid) do
          :ok ->

            {route_type, payload} = if awareness.broadcast == 2 do
              {:broadcast, data}
            else
              {:awareness, awareness}
            end

            server_inbound(payload, :eid, route_type, eid)


          {:error, err} ->
            reason = "Field '#{err.field}' → #{err.description} #{err.code}"
            throws = ThrowProtocolErrorSchema.build(@wareness_id, reason,Until.UniPosTime.response_time())
            socket_outbound(ws_pid, throws)
        end
        {:noreply, mark_active(state)}
      _ ->
        reason = "Unexpected payload received"
        throws = ThrowProtocolErrorSchema.build(@wareness_id, reason, Until.UniPosTime.response_time())
        socket_outbound(ws_pid, throws)
        {:noreply, mark_active(state)}
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

  defp now_ms, do: System.monotonic_time(:millisecond)

  defp mark_active(state) do
    now = now_ms()
    state
    |> Map.put(:last_seen, now)
    |> Map.put(:missed_pongs, 0)
  end

  # defp maybe_report_to_external_service(state) do
  #   now = DateTime.utc_now()

  #   should_report = is_nil(state.last_reported_seen) or
  #                   DateTime.diff(now, state.last_reported_seen, :millisecond) >= state.presence_report_interval
  #   if should_report do

  #     server_inbound(state.device_id, :eid, :ping, state.eid)

  #     %{state | last_reported_seen: now}
  #   else
  #     state
  #   end
  # end


end
