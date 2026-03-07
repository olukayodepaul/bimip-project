defmodule BimipServer.State do
  @moduledoc false

  use Protobuf, enum: true, protoc_gen_elixir_version: "0.15.0", syntax: :proto3

  field :UNKNOWN, 0
  field :CONNECT, 1
  field :DISCONNECT, 2
  field :COMMUNICATION, 3
  field :HEARTBEAT, 4
end
