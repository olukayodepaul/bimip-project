defmodule BimipServer.TunnelMessage do
  @moduledoc false

  use Protobuf, protoc_gen_elixir_version: "0.15.0", syntax: :proto3

  field :id, 1, type: :string
  field :node_id, 2, type: :int32, json_name: "nodeId"
  field :target_node_id, 3, type: :int32, json_name: "targetNodeId"
  field :state, 4, type: BimipServer.State, enum: true
  field :direction, 5, type: BimipServer.Direction, enum: true
  field :payload, 6, type: :bytes
  field :action_type, 7, type: BimipServer.ActionType, json_name: "actionType", enum: true
  field :timestamp, 8, type: :int64
end
