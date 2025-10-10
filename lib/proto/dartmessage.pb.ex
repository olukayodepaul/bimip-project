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

  field :from, 1, type: Bimip.Identity
  field :to, 2, type: Bimip.Identity
  field :type, 3, type: :int32
  field :status, 4, type: :int32
  field :location_sharing, 5, type: :int32, json_name: "locationSharing"
  field :latitude, 6, type: :double
  field :longitude, 7, type: :double
  field :ttl, 8, type: :int32
  field :details, 9, type: :string
  field :timestamp, 10, type: :int64
end

defmodule Bimip.ErrorMessage do
  @moduledoc false

  use Protobuf, protoc_gen_elixir_version: "0.15.0", syntax: :proto3

  field :code, 1, type: :int32
  field :error_origin, 2, type: :int32, json_name: "errorOrigin"
  field :details, 3, type: :string
  field :timestamp, 4, type: :int64
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
  field :details, 7, type: :string
end

defmodule Bimip.TokenRevoke do
  @moduledoc false

  use Protobuf, protoc_gen_elixir_version: "0.15.0", syntax: :proto3

  field :to, 1, type: Bimip.Identity
  field :token, 2, type: :string
  field :type, 3, type: :int32
  field :timestamp, 4, type: :int64
  field :details, 5, type: :string
end

defmodule Bimip.TokenRefresh do
  @moduledoc false

  use Protobuf, protoc_gen_elixir_version: "0.15.0", syntax: :proto3

  field :to, 1, type: Bimip.Identity
  field :refresh_token, 2, type: :string, json_name: "refreshToken"
  field :type, 3, type: :int32
  field :timestamp, 4, type: :int64
  field :details, 5, type: :string
end

defmodule Bimip.AwarenessSubscribe do
  @moduledoc false

  use Protobuf, protoc_gen_elixir_version: "0.15.0", syntax: :proto3

  field :from, 1, type: Bimip.Identity
  field :to, 2, type: Bimip.Identity
  field :tracking_id, 3, type: :string, json_name: "trackingId"
  field :one_way, 4, type: :bool, json_name: "oneWay"
  field :type, 5, type: :int32
  field :timestamp, 6, type: :int64
  field :details, 7, type: :string
end

defmodule Bimip.AwarenessUnsubscribe do
  @moduledoc false

  use Protobuf, protoc_gen_elixir_version: "0.15.0", syntax: :proto3

  field :from, 1, type: Bimip.Identity
  field :to, 2, type: Bimip.Identity
  field :tracking_id, 3, type: :string, json_name: "trackingId"
  field :type, 4, type: :int32
  field :timestamp, 5, type: :int64
  field :details, 6, type: :string
end

defmodule Bimip.Logout do
  @moduledoc false

  use Protobuf, protoc_gen_elixir_version: "0.15.0", syntax: :proto3

  field :to, 1, type: Bimip.Identity
  field :type, 2, type: :int32
  field :status, 3, type: :int32
  field :timestamp, 4, type: :int64
  field :details, 5, type: :string
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

  field :awareness_subscribe, 6,
    type: Bimip.AwarenessSubscribe,
    json_name: "awarenessSubscribe",
    oneof: 0

  field :awareness_unsubscribe, 7,
    type: Bimip.AwarenessUnsubscribe,
    json_name: "awarenessUnsubscribe",
    oneof: 0

  field :logout, 14, type: Bimip.Logout, oneof: 0
  field :error, 15, type: Bimip.ErrorMessage, oneof: 0
end
