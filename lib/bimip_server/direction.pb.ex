defmodule BimipServer.Direction do
  @moduledoc false

  use Protobuf, enum: true, protoc_gen_elixir_version: "0.15.0", syntax: :proto3

  field :DIR_UNKNOWN, 0
  field :CLIENT_TO_SERVER, 1
  field :SERVER_TO_CLIENT, 2
end
