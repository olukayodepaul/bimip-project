protoc \
 --proto_path=./priv/protos \
 --elixir_out=plugins=grpc:./lib/bimip_protocol \
 ./priv/protos/dartmessage.proto

protoc \
 --proto_path=./priv/protos \
 --elixir_out=plugins=grpc:./lib/proto \
 ./priv/protos/log.proto

protoc \
 --proto_path=./priv/protos \
 --elixir_out=plugins=grpc:./lib/proto \
 ./priv/protos/bimip_server.proto


protoc \
  --proto_path=./priv/protos \
  --elixir_out=one_file_per_module=true,plugins=grpc:./lib \
  ./priv/protos/bimip_server.proto