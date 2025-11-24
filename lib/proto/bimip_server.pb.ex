defmodule BimipServer.AuthReply do
  @moduledoc false

  use Protobuf, protoc_gen_elixir_version: "0.15.0", syntax: :proto3

  field :status, 1, type: :int32
  field :type, 2, type: :int32
  field :jti, 3, type: :string
  field :message, 4, type: :string
  field :device_id, 5, type: :string, json_name: "deviceId"
  field :jid, 6, type: :string
end

defmodule BimipServer.AuthRequest do
  @moduledoc false

  use Protobuf, protoc_gen_elixir_version: "0.15.0", syntax: :proto3

  field :token, 1, type: :string
  field :type, 2, type: :int32
end

defmodule BimipServer.GenerateTokenReq do
  @moduledoc false

  use Protobuf, protoc_gen_elixir_version: "0.15.0", syntax: :proto3

  field :jid, 1, type: :string
  field :device_id, 2, type: :string, json_name: "deviceId"
  field :user_id, 3, type: :int32, json_name: "userId"
end

defmodule BimipServer.GenerateTokenRes do
  @moduledoc false

  use Protobuf, protoc_gen_elixir_version: "0.15.0", syntax: :proto3

  field :status, 1, type: :string
  field :refresh_token, 2, type: :string, json_name: "refreshToken"
  field :access_token, 3, type: :string, json_name: "accessToken"
  field :message, 4, type: :string
end

defmodule BimipServer.BlackListTokenReq do
  @moduledoc false

  use Protobuf, protoc_gen_elixir_version: "0.15.0", syntax: :proto3

  field :token, 1, type: :string
end

defmodule BimipServer.BlackListTokenRes do
  @moduledoc false

  use Protobuf, protoc_gen_elixir_version: "0.15.0", syntax: :proto3

  field :status, 1, type: :string
  field :message, 4, type: :string
end

defmodule BimipServer.GenerateAccessTokenFromRefreshTokenReq do
  @moduledoc false

  use Protobuf, protoc_gen_elixir_version: "0.15.0", syntax: :proto3

  field :token, 1, type: :string
end

defmodule BimipServer.GenerateAccessTokenFromRefreshTokenRes do
  @moduledoc false

  use Protobuf, protoc_gen_elixir_version: "0.15.0", syntax: :proto3

  field :status, 1, type: :string
  field :refresh_token, 2, type: :string, json_name: "refreshToken"
  field :access_token, 3, type: :string, json_name: "accessToken"
  field :message, 4, type: :string
end

defmodule BimipServer.AwarenessVisibilityReq do
  @moduledoc false

  use Protobuf, protoc_gen_elixir_version: "0.15.0", syntax: :proto3

  field :id, 1, type: :string
  field :eid, 2, type: :string
  field :device_id, 3, type: :string, json_name: "deviceId"
  field :type, 4, type: :int32
  field :timestamp, 5, type: :int64
end

defmodule BimipServer.AwarenessVisibilityRes do
  @moduledoc false

  use Protobuf, protoc_gen_elixir_version: "0.15.0", syntax: :proto3

  field :id, 1, type: :string
  field :eid, 2, type: :string
  field :device_id, 3, type: :string, json_name: "deviceId"
  field :type, 4, type: :int32
  field :timestamp, 5, type: :int64
  field :status, 6, type: :int32
  field :message, 7, type: :string
  field :display_name, 8, type: :string, json_name: "displayName"
end

defmodule BimipServer.BimipService.Service do
  @moduledoc false

  use GRPC.Service, name: "bimip_server.BimipService", protoc_gen_elixir_version: "0.15.0"

  rpc :DeviceAuth, BimipServer.AuthRequest, BimipServer.AuthReply

  rpc :GenerateDeviceToken, BimipServer.GenerateTokenReq, BimipServer.GenerateTokenRes

  rpc :BlackListToken, BimipServer.BlackListTokenReq, BimipServer.BlackListTokenRes

  rpc :GenAccessFromRefreshToken,
      BimipServer.GenerateAccessTokenFromRefreshTokenReq,
      BimipServer.GenerateAccessTokenFromRefreshTokenRes

  rpc :AwarenessVisibility, BimipServer.AwarenessVisibilityReq, BimipServer.AwarenessVisibilityRes
end

defmodule BimipServer.BimipService.Stub do
  @moduledoc false

  use GRPC.Stub, service: BimipServer.BimipService.Service
end
