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
        {Task.Supervisor, name: Message.TaskSupervisor}
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
end
