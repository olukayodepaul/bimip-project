defmodule Bimip.Identity do
  @moduledoc false

  use Protobuf, protoc_gen_elixir_version: "0.15.0", syntax: :proto3

  field :eid, 1, type: :string

  field :connection_resource_id, 2,
    proto3_optional: true,
    type: :string,
    json_name: "connectionResourceId"
end

defmodule Bimip.Awareness do
  @moduledoc false

  use Protobuf, protoc_gen_elixir_version: "0.15.0", syntax: :proto3

  field :from, 1, type: :string
  field :to, 2, type: :string
  field :status, 3, type: :int32
  field :location_sharing, 4, type: :bool, json_name: "locationSharing"
  field :latitude, 5, type: :double
  field :longitude, 6, type: :double
  field :intention, 7, type: :int32
  field :timestamp, 8, type: :int64
end

defmodule Bimip.ErrorMessage do
  @moduledoc false

  use Protobuf, protoc_gen_elixir_version: "0.15.0", syntax: :proto3

  field :code, 1, type: :int32
  field :error_origin, 2, type: :int32, json_name: "errorOrigin"
  field :details, 3, type: :string
  field :timestamp, 4, type: :int64
end

defmodule Bimip.Logout do
  @moduledoc false

  use Protobuf, protoc_gen_elixir_version: "0.15.0", syntax: :proto3

  field :to, 1, type: Bimip.Identity
  field :type, 2, type: :int32
  field :status, 3, type: :int32
  field :timestamp, 4, type: :int64
  field :reason, 5, type: :string
end

defmodule Bimip.PingPong do
  @moduledoc false

  use Protobuf, protoc_gen_elixir_version: "0.15.0", syntax: :proto3

  field :from, 1, type: Bimip.Identity
  field :to, 2, type: Bimip.Identity
  field :resource, 3, type: :int32
  field :type, 4, type: :int32
  field :ping_time, 5, type: :int64, json_name: "pingTime"
  field :pong_time, 6, type: :int64, json_name: "pongTime"
  field :error_reason, 7, type: :string, json_name: "errorReason"
end

defmodule Bimip.TokenRevoke do
  @moduledoc false

  use Protobuf, protoc_gen_elixir_version: "0.15.0", syntax: :proto3

  field :to, 1, type: Bimip.Identity
  field :token, 2, type: :string
  field :phase, 3, type: :int32
  field :timestamp, 4, type: :int64
  field :reason, 5, type: :string
end

defmodule Bimip.TokenRefresh do
  @moduledoc false

  use Protobuf, protoc_gen_elixir_version: "0.15.0", syntax: :proto3

  field :to, 1, type: Bimip.Identity
  field :refresh_token, 2, type: :string, json_name: "refreshToken"
  field :phase, 3, type: :int32
  field :timestamp, 4, type: :int64
end

defmodule Bimip.SubscribeRequest do
  @moduledoc false

  use Protobuf, protoc_gen_elixir_version: "0.15.0", syntax: :proto3

  field :from, 1, type: Bimip.Identity
  field :to, 2, type: Bimip.Identity
  field :subscription_id, 3, type: :string, json_name: "subscriptionId"
  field :one_way, 4, type: :bool, json_name: "oneWay"
  field :timestamp, 5, type: :int64
end

defmodule Bimip.SubscribeResponse do
  @moduledoc false

  use Protobuf, protoc_gen_elixir_version: "0.15.0", syntax: :proto3

  field :from, 1, type: Bimip.Identity
  field :to, 2, type: Bimip.Identity
  field :status, 3, type: :int32
  field :message, 4, type: :string
  field :subscription_id, 5, type: :string, json_name: "subscriptionId"
  field :one_way, 6, type: :bool, json_name: "oneWay"
  field :timestamp, 7, type: :int64
end

defmodule Bimip.UnsubscribeRequest do
  @moduledoc false

  use Protobuf, protoc_gen_elixir_version: "0.15.0", syntax: :proto3

  field :from, 1, type: Bimip.Identity
  field :to, 2, type: Bimip.Identity
  field :timestamp, 3, type: :int64
  field :force_two_way_removal, 4, type: :bool, json_name: "forceTwoWayRemoval"
end

defmodule Bimip.UnsubscribeResponse do
  @moduledoc false

  use Protobuf, protoc_gen_elixir_version: "0.15.0", syntax: :proto3

  field :from, 1, type: Bimip.Identity
  field :to, 2, type: Bimip.Identity
  field :status, 3, type: :int32
  field :message, 4, type: :string
  field :timestamp, 5, type: :int64
  field :two_way_removed, 6, type: :bool, json_name: "twoWayRemoved"
end

defmodule Bimip.MessageScheme do
  @moduledoc false

  use Protobuf, protoc_gen_elixir_version: "0.15.0", syntax: :proto3

  oneof :payload, 0

  field :route, 1, type: :int64
  field :awareness, 2, type: Bimip.Awareness, oneof: 0
  field :ping_pong, 3, type: Bimip.PingPong, json_name: "pingPong", oneof: 0
  field :token_revoke, 4, type: Bimip.TokenRevoke, json_name: "tokenRevoke", oneof: 0
  field :token_refresh, 5, type: Bimip.TokenRefresh, json_name: "tokenRefresh", oneof: 0

  field :subscribe_request, 6,
    type: Bimip.SubscribeRequest,
    json_name: "subscribeRequest",
    oneof: 0

  field :subscribe_response, 7,
    type: Bimip.SubscribeResponse,
    json_name: "subscribeResponse",
    oneof: 0

  field :unsubscribe_request, 8,
    type: Bimip.UnsubscribeRequest,
    json_name: "unsubscribeRequest",
    oneof: 0

  field :unsubscribe_response, 9,
    type: Bimip.UnsubscribeResponse,
    json_name: "unsubscribeResponse",
    oneof: 0

  field :logout, 10, type: Bimip.Logout, oneof: 0
  field :error, 11, type: Bimip.ErrorMessage, oneof: 0
end
