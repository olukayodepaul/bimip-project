defmodule BimipServer.BimipService.Service do
  @moduledoc false

  use GRPC.Service, name: "bimip_server.BimipService", protoc_gen_elixir_version: "0.15.0"

  rpc :BimipTunnel, stream(BimipServer.TunnelMessage), stream(BimipServer.TunnelMessage)
end

defmodule BimipServer.BimipService.Stub do
  @moduledoc false

  use GRPC.Stub, service: BimipServer.BimipService.Service
end
