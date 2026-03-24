# -----------------------
# Bimip.Application
# -----------------------
defmodule Bimip.Application do
  use Application

  require Logger

  @impl true
  def start(_type, _args) do

    # -----------------------
    # COWBOY CONNECTIONS
    # -----------------------
    connections_children = []

    # TLS server
    connections_children =
      if  Application.Config.secure_tls?() do
        tls_child = %{
          id: :https,
          start:
            {:cowboy, :start_tls,
             [
               :https,
               [
                 port: Application.Config.tls_port(),
                 certfile: Application.Config.cert_file(),
                 keyfile: Application.Config.key_file()
               ],
               # Hand over the resource_path to the dispatch function
               %{env: %{dispatch: dispatch(Application.Config.resource_path())}}
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
           [port: Application.Config.clear_port()],
           # Hand over the resource_path to the dispatch function
           %{env: %{dispatch: dispatch(Application.Config.resource_path())}}
         ]}
    }

    connections_children = [non_tls_child | connections_children]

    # -----------------------
    # SUPERVISION TREE
    # -----------------------
    children = connections_children ++
      [
        {Phoenix.PubSub,
          name: Bimip.PubSub,
          pool_size: 32,      # Number of concurrent registry workers
          pool_overflow: 5,   # Extra workers if busy
          adapter: Phoenix.PubSub.PG2
        },
        {Redix, name: :redix},
        {Horde.Registry, name: DeviceIdRegistry, keys: :unique, members: :auto},
        {Horde.Registry, name: EidRegistry, keys: :unique, members: :auto},
        %{id: :pg, start: {:pg, :start_link, [BimipGroups]}},
        {Supervisor.Server, []},
        {Supervisor.Client, []},
        {Queue.BimipSupervisor, []},
        # {BimipsSignal.SignalManager, []},
        {Task.Supervisor, name: Message.TaskSupervisor}
      ]

    opts = [strategy: :one_for_one, name: Bimip.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # -----------------------
  # COWBOY DISPATCH
  # -----------------------
  # Accept the path as an argument to resolve the "undefined variable" error
  defp dispatch(path) do
    :cowboy_router.compile([
      {:_, [{path, Bimip.Socket, []}]}
    ])
  end
end
