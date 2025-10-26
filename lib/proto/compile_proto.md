protoc \
 --proto_path=./priv/protos \
 --elixir_out=plugins=grpc:./lib/proto \
 ./priv/protos/dartmessage.proto
