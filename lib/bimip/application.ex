defmodule Bimip.Application do
  use Application
  alias Settings.Connections
  require Logger

  @impl true
  def start(_type, _args) do
    :mnesia.stop()
    # :mnesia.delete_schema([node()])
    :mnesia.create_schema([node()])
    :mnesia.start()

    # Tables
    ensure_subscriber()
    ensure_device_table()
    ensure_device_index()
    first_segment()
    ensure_ack_table()
    ensure_next_offsets_table()
    ensure_device_offsets_table()
    ensure_current_segment_table()
    ensure_user_state_table()
    
    
    ensure_user_awareness_table()
    ensure_queue()
    ensure_queuing_index()

    # TCP / HTTP
    tcp_connection =
      if Connections.secure_tls?() do
        %{
          id: :https,
          start: {:cowboy, :start_tls,
                  [:https,
                   [port: Connections.port(), certfile: Connections.cert_file(), keyfile: Connections.key_file()],
                   %{env: %{dispatch: dispatch()}}]}
        }
      else
        %{
          id: :http,
          start: {:cowboy, :start_clear, [:http, [port: Connections.port()], %{env: %{dispatch: dispatch()}}]}
        }
      end

    children = [
      tcp_connection,
      {Phoenix.PubSub, name: Bimip.PubSub},
      {Redix, name: :redix},
      {Horde.Registry, name: DeviceIdRegistry, keys: :unique, members: :auto},
      {Horde.Registry, name: EidRegistry, keys: :unique, members: :auto},
      {Bimip.Supervisor.Orchestrator, []},
      {Bimip.Device.Supervisor, []}
    ]

    opts = [strategy: :one_for_one, name: Bimip.Supervisor]
    Supervisor.start_link(children, opts)
  end

  defp dispatch do
    :cowboy_router.compile([
      {:_, [{Connections.resource_path(), Bimip.Socket, []}]}
    ])
  end

  # ----------------------
  # Generic table creator
  # ----------------------
  defp ensure_table(table, opts) do
    case :mnesia.create_table(table, opts) do
      {:atomic, :ok} -> Logger.info("✅ Table #{inspect(table)} created")
      {:aborted, {:already_exists, ^table}} -> Logger.info("ℹ️ Table #{inspect(table)} already exists")
      other -> Logger.error("⚠️ Failed to create table #{inspect(table)}: #{inspect(other)}")
    end
  end

  # ----------------------
  # Device & Index tables
  # ----------------------
  defp ensure_device_table do
    ensure_table(:device, [
      {:attributes, [:key, :payload, :last_offset, :timestamp]},
      {:disc_copies, [node()]},
      {:type, :set}
    ])
  end

  defp ensure_device_index do
    ensure_table(:device_index, [
      {:attributes, [:eid, :device_id]},
      {:disc_copies, [node()]},
      {:type, :bag} # multiple devices per eid
    ])
  end

  defp ensure_user_awareness_table do
    ensure_table(:user_awareness_table, [
      {:attributes, [:key, :awareness, :timestamp]},
      {:disc_copies, [node()]},
      {:type, :set}
    ])
  end

  defp ensure_user_state_table do
    ensure_table(:track_eid_state, [
      {:attributes, [:eid, :state]},
      {:disc_copies, [node()]},
      {:type, :set}
    ])
  end

  # -----------------------------
  # Ensure tables exist
  # -----------------------------
  def ensure_subscriber do
    :mnesia.create_table(:subscribers, [
      {:attributes, [:id, :owner_id, :subscriber_id, :status, :blocked, :inserted_at, :last_seen]},
      {:type, :set},
      {:disc_copies, [node()]}
    ])

    :mnesia.create_table(:subscriber_index, [
      {:attributes, [:owner_id, :subscriber_id]},
      {:type, :bag},
      {:disc_copies, [node()]}
    ])
  end


  # ----------------------
  # First / Current segment tables
  # ----------------------
  defp first_segment do
    ensure_table(:first_segment, [
      {:attributes, [:key, :segment]}, # key = {user, partition_id}
      {:disc_copies, [node()]},
      {:type, :set}
    ])
  end

  defp ensure_current_segment_table do
    ensure_table(:current_segment, [
      {:attributes, [:key, :segment]}, # key = {user, partition_id}
      {:disc_copies, [node()]},
      {:type, :set}
    ])
  end

  # ----------------------
  # Next offsets (per user + partition)
  # ----------------------
  defp ensure_next_offsets_table do
    ensure_table(:next_offsets, [
      {:attributes, [:key, :offset]}, # key = {user, partition_id}
      {:disc_copies, [node()]},
      {:type, :set}
    ])
  end

  # ----------------------
  # Device offsets (per user + device + partition)
  # ----------------------
  defp ensure_device_offsets_table do
    ensure_table(:device_offsets, [
      {:attributes, [:key, :offset]}, # key = {user, device_id, partition_id}
      {:disc_copies, [node()]},
      {:type, :set}
    ])
  end


  defp ensure_ack_table do
    ensure_table(:ack_table, [
      {:attributes, [:key, :last_ack]}, # key = {user, device_id, partition_id}
      {:disc_copies, [node()]},
      {:type, :set}
    ])
  end


  # ----------------------
  # Queue & Queue index tables
  # ----------------------
  defp ensure_queue do
    ensure_table(:queue, [
      {:attributes, [:key, :payload, :timestamp]},
      {:disc_copies, [node()]},
      {:type, :set}
    ])
  end

  defp ensure_queuing_index do
    ensure_table(:queuing_index, [
      {:attributes, [:eid, :max_id, :last_offset]},
      {:disc_copies, [node()]},
      {:type, :set}
    ])
  end
end
