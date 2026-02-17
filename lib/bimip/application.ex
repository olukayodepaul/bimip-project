# -----------------------
# Bimip.Application
# -----------------------
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
      :ok -> Logger.info("Schema created.")
      {:error, {_, {:already_exists, _}}} -> :ok
    end

    :mnesia.start()
    :mnesia.wait_for_tables([], 5_000)
    create_all_bimip_tables()

    # -----------------------
    # COWBOY CONNECTIONS
    # -----------------------
    connections_children = []

    # TLS server
    connections_children =
      if Connections.secure_tls?() do
        tls_child = %{
          id: :https,
          start:
            {:cowboy, :start_tls,
             [
               :https,
               [
                 port: Connections.tls_port(),
                 certfile: Connections.cert_file(),
                 keyfile: Connections.key_file()
               ],
               %{env: %{dispatch: dispatch()}}
             ]}
        }

        [tls_child | connections_children]
      else
        connections_children
      end

    # Non-TLS server
    non_tls_child = %{
      id: :http,
      start:
        {:cowboy, :start_clear,
         [
           :http,
           [port: Connections.clear_port()],
           %{env: %{dispatch: dispatch()}}
         ]}
    }

    connections_children = [non_tls_child | connections_children]

    # -----------------------
    # SUPERVISION TREE
    # -----------------------
    children = connections_children ++
      [
        {Phoenix.PubSub, name: Bimip.PubSub},
        {Redix, name: :redix},
        {Horde.Registry, name: DeviceIdRegistry, keys: :unique, members: :auto},
        {Horde.Registry, name: EidRegistry, keys: :unique, members: :auto},
        {Supervisor.Server, []},
        {Supervisor.Client, []},
        {Queue.BimipSupervisor, []},
        {Task.Supervisor, name: Chat.TaskSupervisor}
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
  # MNESIA TABLE DEFINITIONS
  # -----------------------
  defp create_all_bimip_tables do
    create(:registration, [:key, :eid, :visibility, :display_name, :timestamp], :set)
    create(:device, [:key, :payload, :last_offset, :timestamp], :set)
    create(:device_index, [:eid, :device_id], :bag)
    create(:subscribers, [:id, :owner_id, :subscriber_id, :status, :blocked, :inserted_at, :last_seen], :set)
    create(:subscriber_index, [:owner_id, :subscriber_id], :bag)
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
      {:atomic, :ok} -> Logger.info("Created table #{inspect(table_name)}")
      {:aborted, {:already_exists, _}} -> Logger.debug("Table #{inspect(table_name)} already exists. Skipping.")
      other -> Logger.error("Failed creating #{inspect(table_name)}: #{inspect(other)}"); other
    end
  end
end
