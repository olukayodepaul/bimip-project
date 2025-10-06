defmodule Bimip.Device.Client do
  #bimip
  use GenServer
  alias Bimip.Registry
  alias Settings.AdaptiveNetwork
  alias Util.Network.AdaptivePingPong
  alias App.RegistryHub

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
        last_activity:  DateTime.utc_now()
      }
    }}
  end

  # Handle ping/pong
  @impl true
  def handle_info({:send_ping, interval}, state) do
    AdaptivePingPong.handle_ping(%{state | last_rtt: interval} )
  end

  @impl true
  def handle_cast({:received_pong, {device_id, receive_time}}, state) do 
    AdaptivePingPong.pongs_received(device_id, receive_time, state)
  end

  def handle_cast({:send_terminate_signal_to_client, {device_id, eid}}, state) do
    IO.inspect("CLIENT")
    RegistryHub.send_terminate_signal_to_server({device_id, eid})
    {:stop, :normal, state}
  end



end

# Bimip.Device.Client.get_state("aaaaa2")



