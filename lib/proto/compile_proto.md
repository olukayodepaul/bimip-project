protoc \
 --proto_path=./priv/protos \
 --elixir_out=plugins=grpc:./lib/proto \
 ./priv/protos/dartmessage.proto

protoc \
 --proto_path=./priv/protos \
 --elixir_out=plugins=grpc:./lib/proto \
 ./priv/protos/log.proto

protoc \
 --proto_path=./priv/protos \
 --elixir_out=plugins=grpc:./lib/proto \
 ./priv/protos/bimip_server.proto
