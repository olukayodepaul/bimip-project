defmodule Bimip.Broker.Server do
  #brokers
  use Phoenix.Presence,
    otp_app: :bimip_presence_broker,
    pubsub_server: Bimip.PubSub
end