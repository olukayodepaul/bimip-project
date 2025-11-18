defmodule Supervisor.Client do
  #supervisor

use Horde.DynamicSupervisor
  require Logger

  @moduledoc """
  Dynamic supervisor for all device session children.
  """

  def start_link(_args) do
    Horde.DynamicSupervisor.start_link(__MODULE__, :ok, name: __MODULE__)
  end

  def init(:ok) do
    Horde.DynamicSupervisor.init(strategy: :one_for_one)
  end

  @spec start_session({ any(), any(), any(), pid()}) :: {:ok, pid()} | {:error, any()}
  def start_session({eid, device_id, _exp, _ws_pid} = state) do
    child_spec = %{
      id: {:device_session, device_id},
      start: {Bimip.SignalClient, :start_link, [state]},
      restart: :transient,
      shutdown: 5000
    }

    case Horde.DynamicSupervisor.start_child(__MODULE__, child_spec) do
      {:ok, pid} ->
        Logger.info("Bimip.Device.Client Session started for eid=#{eid}, device_id=#{device_id}, pid=#{inspect(pid)}")
        {:ok, pid}

      {:error, {:already_started, pid}} ->
        Logger.warning("Bimip.Device.Client Session already exists for device_id=#{device_id}, pid=#{inspect(pid)}")
        {:ok, pid}

      {:error, reason} ->
        Logger.error("Bimip.Device.Client Failed to start session for device_id=#{device_id}, reason=#{inspect(reason)}")
        {:error, reason}
    end
  end
end
