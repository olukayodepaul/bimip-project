//Server one
export RELEASE_DISTRIBUTION=name
export RELEASE_NODE=bimip-server-1@127.0.0.1
export RELEASE_COOKIE=mysecret
bimip start_iex

//Server two
export RELEASE_DISTRIBUTION=name
export RELEASE_NODE=bimip-server-2@127.0.0.1
export RELEASE_COOKIE=mysecret
bimip start_iex

Node.connect(:"bimip-server-1@127.0.0.1")
Node.connect(:"bimip-server-2@127.0.0.1")

Node.list() # Should show [:server2@HOST] on server1

`{:ok, _} = Horde.Registry.start_link(
  name: EidRegistry,
  keys: :unique,
  members: :auto
)`

Horde.Cluster.join(EidRegistry, :global) # optional helper if using libcluster

{:ok, \_} = Horde.DynamicSupervisor.start_link(
name: GlobalMotherSupervisor,
strategy: :one_for_one,
members: :auto
)
