defmodule Bimip.Application do
  use Application
  alias Settings.Connections
  require Logger

  @impl true
  def start(_type, _args) do
    :mnesia.stop()
    # :mnesia.delete_schema([node()])
    case :mnesia.create_schema([node()]) do
      :ok -> Logger.info("Schema created.")
      {:error, {_, {:already_exists, _}}} -> :ok
    end
    :mnesia.start()
    :mnesia.wait_for_tables([], 5000)

    # Tables
    create_all_bimip_tables()

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
      {Supervisor.Server, []},
      {Supervisor.Client, []}
    ]

    opts = [strategy: :one_for_one, name: Bimip.Supervisor]
    Supervisor.start_link(children, opts)
  end

  defp dispatch do
    :cowboy_router.compile([
      {:_, [{Connections.resource_path(), Bimip.Socket, []}]}
    ])
  end

  defp create_all_bimip_tables do
    create(:registration, [:key, :eid,  :visibility, :display_name,  :timestamp], :set)
    create(:device, [:key, :payload, :last_offset, :timestamp], :set)
    create(:device_index, [:eid, :device_id], :bag)
    create(:subscribers, [:id, :owner_id, :subscriber_id, :status, :blocked, :inserted_at, :last_seen], :set)
    create(:subscriber_index, [:owner_id, :subscriber_id], :bag)


    create(:current_segment, [:key, :segment], :set)
    create(:first_segment, [:key, :segment], :set)
    create(:next_offsets, [:key, :offset], :set)
    create(:segment_cache, [:key, :segment, :position], :set)
    create(:commit_offsets, [:key, :offset], :set)
    create(:pending_acks, [:key, :offsets], :set)   # original pending

    # New per-status pending and commit tables
    create(:pending_sent, [:key, :set], :set)
    create(:pending_delivered, [:key, :set], :set)
    create(:pending_read, [:key, :set], :set)
    create(:commit_sent, [:key, :offset], :set)
    create(:commit_delivered, [:key, :offset], :set)
    create(:commit_read, [:key, :offset], :set)
    create(:resume_grace, [:key, :timestamp], :set)

  end

  # ----------------------
  # GENERIC TABLE CREATOR
  # ----------------------
  defp create(table_name, attributes, type) do
    case :mnesia.create_table(table_name, [
          {:attributes, attributes},
          {:disc_copies, [node()]},
          {:type, type}
        ]) do
      {:atomic, :ok} ->
        Logger.info(" Created table #{inspect(table_name)}")

      {:aborted, {:already_exists, _}} ->
        Logger.debug("Table #{inspect(table_name)} already exists. Skipping.")

      other ->
        Logger.error(" Failed creating #{inspect(table_name)}: #{inspect(other)}")
        other
    end
  end

end
