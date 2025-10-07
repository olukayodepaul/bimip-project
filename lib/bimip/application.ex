defmodule Bimip.Application do
  #bimip

  use Application
  alias Settings.Connections
  require Logger


  @impl true
  def start(_type, _args) do
    
    :mnesia.stop()
    # :mnesia.delete_schema([node()])
    :mnesia.create_schema([node()])
    :mnesia.start() 
    ensure_device_table()
    ensure_device_index()
    ensure_user_state_table()
    ensure_subscriber_table()
    ensure_subscriber_index()
    ensure_user_awareness_table()
    ensure_queue()
    ensure_queuing_index()

    tcp_connection =
      if Connections.secure_tls?() do
        %{
          id: :https,
          start:
            {:cowboy, :start_tls,
              [
                :https,
                [
                  port: Connections.port(),
                  certfile: Connections.cert_file(),
                  keyfile: Connections.key_file()
                ],
                %{env: %{dispatch: dispatch()}}
              ]}
        }
      else
        %{
          id: :http,
          start:
            {:cowboy, :start_clear,
              [:http, [port: Connections.port()], %{env: %{dispatch: dispatch()}}]}
        }
      end

    children = [
      tcp_connection,
      {Phoenix.PubSub, name: Bimip.PubSub},
      {Redix, name: :redix},
      {Horde.Registry, name: DeviceIdRegistry, keys: :unique, members: :auto},
      {Horde.Registry, name: EidRegistry, keys: :unique, members: :auto},
      {Bimip.Supervisor.Orchestrator, []},
      {Bimip.Device.Supervisor, []},
    ]

    opts = [strategy: :one_for_one, name: Bimip.Supervisor]
    Supervisor.start_link(children, opts)
  end

  defp dispatch do
    :cowboy_router.compile([
      {:_,
        [
          {Connections.resource_path(), Bimip.Socket, []}
        ]}
    ])
  end

  # Create table safely
  defp ensure_table(table, opts) do
    case :mnesia.create_table(table, opts) do
      {:atomic, :ok} ->
        Logger.info("✅ InMemory table #{inspect(table)} created")

      {:aborted, {:already_exists, ^table}} ->
        Logger.info("ℹ️ InMemory table #{inspect(table)} already exists")

      other ->
        Logger.error("⚠️ Failed to create table #{inspect(table)}: #{inspect(other)}")
    end
  end

  # Device table
  defp ensure_device_table do
    ensure_table(:device, [
      {:attributes, [:key, :payload, :last_offset, :timestamp]},
      {:disc_copies, [node()]},
      {:type, :set}
    ])
  end

  # Device table
  defp ensure_user_awareness_table do
    ensure_table(:user_awareness_table, [
      {:attributes, [:key, :awareness, :lat, :lng,  :status_broadcast, :timestamp]},
      {:disc_copies, [node()]},
      {:type, :set}
    ])
  end

  # Device index table
  defp ensure_device_index do
    ensure_table(:device_index, [
      {:attributes, [:eid, :device_id]}, # use :eid as the first field
      {:disc_copies, [node()]},
      {:type, :bag} # allows multiple device_ids per eid
    ])
  end

  def ensure_user_state_table do
    case :mnesia.create_table(:track_eid_state, [
            {:attributes, [:eid, :state]},
            {:disc_copies, [node()]},
            {:type, :set}
          ]) do
      {:atomic, :ok} -> Logger.info("✅ User state table created")
      {:aborted, {:already_exists, _}} -> :ok
      other -> Logger.error("⚠️ Failed to create table: #{inspect(other)}")
    end
  end

  # -----------------------------
  # Table creation
  # -----------------------------
  def ensure_subscriber_table do
    case :mnesia.create_table(:subscriber, [
          {:attributes, [:key, :owner_eid, :subscriber_eid, :status, :blocked, :inserted_at, :last_seen]},
          {:disc_copies, [node()]},
          {:type, :set}
        ]) do
      {:atomic, :ok} -> Logger.info("✅ Subscriber table created")
      {:aborted, {:already_exists, _}} -> :ok
      other -> Logger.error("⚠️ Failed to create subscriber table: #{inspect(other)}")
    end
  end

  def ensure_subscriber_index do
    case :mnesia.create_table(:subscriber_index, [
          {:attributes, [:owner_eid, :subscriber_eid]},
          {:disc_copies, [node()]},
          {:type, :bag} # multiple owners can have same subscriber
        ]) do
      {:atomic, :ok} -> Logger.info("✅ Subscriber index table created")
      {:aborted, {:already_exists, _}} -> :ok
      other -> Logger.error("⚠️ Failed to create subscriber index table: #{inspect(other)}")
    end
  end


  @doc """
  Ensures the queuing_index table exists.
  - eid: Entity ID (owner of the queue)
  - channel: Queue channel (:sub, :block_sub, etc.)
  - max_id: Highest message id assigned so far
  - last_offset: Last consumed offset for FIFO tracking
  """
  def ensure_queuing_index do
    case :mnesia.create_table(:queuing_index, [
          {:attributes, [:eid, :max_id, :last_offset]},
          {:disc_copies, [node()]},
          {:type, :set}
        ]) do
      {:atomic, :ok} ->
        Logger.info("✅ queuing_index table created")

      {:aborted, {:already_exists, _}} ->
        :ok

      other ->
        Logger.error("⚠️ Failed to create queuing_index table: #{inspect(other)}")
    end
  end

  @doc """
  Ensures the queue table exists.
  - eid: Entity ID (owner of the queue)
  - msg_id: Sequential message id
  - payload: Message content
  - timestamp: Insert time
  """
  def ensure_queue do
    case :mnesia.create_table(:queue, [
          {:attributes, [:key, :payload, :timestamp]},
          {:disc_copies, [node()]},
          {:type, :set}
        ]) do
      {:atomic, :ok} ->
        Logger.info("✅ queue table created")

      {:aborted, {:already_exists, _}} ->
        :ok

      other ->
        Logger.error("⚠️ Failed to create queue table: #{inspect(other)}")
    end
  end

end












