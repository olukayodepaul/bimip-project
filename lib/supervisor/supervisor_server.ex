defmodule Supervisor.Server do
  #supervisor

  use Horde.DynamicSupervisor
  require Logger

  @moduledoc """
  Dynamic supervisor for all Mother processes (per user).
  """

  def start_link(_args) do
    Horde.DynamicSupervisor.start_link(__MODULE__, :ok, name: __MODULE__)
  end

  def init(:ok) do
    Horde.DynamicSupervisor.init(strategy: :one_for_one, members: :auto)
  end

  @spec start_mother(state :: map()) :: {:ok, pid} | {:error, any()}
  def start_mother(%{eid: eid}) do
    child_spec = %{
      id: {:orchestrator_session, eid},                  # unique per user
      # Only the eid: Horde replays these args on a restart, so they must not
      # carry per-connection data (ws_pid, device_id, token) that goes stale.
      start: {Bimip.SignalServer, :start_link, [%{eid: eid}]},
      restart: :transient,
      shutdown: 5000
    }

    case Horde.DynamicSupervisor.start_child(__MODULE__, child_spec) do
      {:ok, pid} ->
        Logger.info("Bimip.Service.Master started for eid=#{eid}, pid=#{inspect(pid)}")
        {:ok, pid}

      {:error, {:already_started, pid}} ->
        Logger.info("Bimip.Service.Master already running for eid=#{eid}, pid=#{inspect(pid)}")
        {:ok, pid}

      {:error, reason} ->
        Logger.error("Failed to start Bimip.Service.Master for eid=#{eid}, reason=#{inspect(reason)}")
        {:error, reason}
    end
  end

end
