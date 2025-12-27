defmodule Bimip.Application do
  use Application

  alias Settings.Connections
  require Logger

  @impl true
  def start(_type, _args) do
    # -----------------------
    # MNESIA BOOTSTRAP
    # -----------------------
    :mnesia.stop()
    # :mnesia.delete_schema([node()])

    case :mnesia.create_schema([node()]) do
      :ok ->
        Logger.info("Schema created.")

      {:error, {_, {:already_exists, _}}} ->
        :ok
    end

    :mnesia.start()
    :mnesia.wait_for_tables([], 5_000)

    # -----------------------
    # MNESIA TABLES
    # -----------------------
    create_all_bimip_tables()

    # -----------------------
    # ETS (GLOBAL INDEX CACHE)
    # -----------------------
    init_ets()
    Queue.MessageTracker.init()

    # -----------------------
    # TCP / HTTP
    # -----------------------
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
             [
               :http,
               [port: Connections.port()],
               %{env: %{dispatch: dispatch()}}
             ]}
        }
      end

    # -----------------------
    # SUPERVISION TREE
    # -----------------------
    children = [
      tcp_connection,
      {Phoenix.PubSub, name: Bimip.PubSub},
      {Redix, name: :redix},
      {Horde.Registry, name: DeviceIdRegistry, keys: :unique, members: :auto},
      {Horde.Registry, name: EidRegistry, keys: :unique, members: :auto},
      {Supervisor.Server, []},
      {Supervisor.Client, []},
      {Queue.MessageTracker.Sweeper, []},
    ]

    opts = [strategy: :one_for_one, name: Bimip.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # -----------------------
  # COWBOY DISPATCH
  # -----------------------
  defp dispatch do
    :cowboy_router.compile([
      {:_, [{Connections.resource_path(), Bimip.Socket, []}]}
    ])
  end

  # -----------------------
  # ETS INITIALIZATION
  # -----------------------
  defp init_ets do
    ets_tables = [
      {:bimip_index_cache, [:named_table, :ordered_set, :public, {:read_concurrency, true}, {:write_concurrency, true}]},
      {:bimip_device_bookmarks, [:named_table, :set, :public, {:read_concurrency, true}, {:write_concurrency, true}]},
      {:bimip_poison_tracker, [:named_table, :set, :public, {:read_concurrency, true}, {:write_concurrency, true}]}
    ]

    for {table, opts} <- ets_tables do
      case :ets.info(table) do
        :undefined ->
          :ets.new(table, opts)
          Logger.info("ETS table #{inspect(table)} initialized")
        _ -> :ok
      end
    end
  end

  # -----------------------
  # MNESIA TABLE DEFINITIONS
  # -----------------------
  defp create_all_bimip_tables do
    create(:registration, [:key, :eid, :visibility, :display_name, :timestamp], :set)
    create(:device, [:key, :payload, :last_offset, :timestamp], :set)
    create(:device_index, [:eid, :device_id], :bag)
    create(:subscribers, [:id, :owner_id, :subscriber_id, :status, :blocked, :inserted_at, :last_seen], :set)
    create(:subscriber_index, [:owner_id, :subscriber_id], :bag)

    # Log / Queue metadata
    create(:current_segment, [:key, :segment], :set)
    create(:first_segment, [:key, :segment], :set)
    create(:next_offsets, [:key, :offset], :set)
    create(:commit_offsets, [:key, :offset], :set)
    create(:pending_acks, [:key, :offsets], :set)

    # State helpers
    create(:resume_grace, [:key, :timestamp], :set)
    create(:message_offset, [:key, :offset], :set)
  end

  # -----------------------
  # GENERIC MNESIA CREATOR
  # -----------------------
  defp create(table_name, attributes, type) do
    case :mnesia.create_table(table_name, [
           {:attributes, attributes},
           {:disc_copies, [node()]},
           {:type, type}
         ]) do
      {:atomic, :ok} ->
        Logger.info("Created table #{inspect(table_name)}")

      {:aborted, {:already_exists, _}} ->
        Logger.debug("Table #{inspect(table_name)} already exists. Skipping.")

      other ->
        Logger.error("Failed creating #{inspect(table_name)}: #{inspect(other)}")
        other
    end
  end
end
