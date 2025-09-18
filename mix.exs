defmodule Bimip.MixProject do
  use Mix.Project

  require Logger

  def project do
    [
      app: :bimip,
      version: "0.1.0",
      elixir: "~> 1.18",
      start_permanent: Mix.env() == :prod,
      deps: deps()
    ]
  end

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      extra_applications: [
        :logger,
        :mnesia
        ],
      mod: {Bimip.Application, []}
    ]
  end

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      {:plug_cowboy, "~> 2.7"},
      {:cowboy, "~> 2.13"},
      {:httpoison, "~> 1.8"},
      {:dotenv, "~> 3.0.0"}, # For environment variable loading
      {:jason, "~> 1.4"},
      {:jose, "~> 1.11"}, 
      {:joken, "~> 2.6"}, 
      # {:protobuf_generate, "~> 0.1.1", only: [:dev, :test]}, # Used for the mix proto.gen task itself

      {:grpc, "~> 0.10.1"},
      {:protobuf, "~> 0.15"},
      {:phoenix_pubsub, "~> 2.1"},

      #elixir project
      {:redix, ">= 1.5.0"},
      {:phoenix, "~> 1.7"},
      {:horde, "~> 0.8"},

      {:ecto_sql, "~> 3.11"},
      {:postgrex, ">= 0.0.0"},
      {:mongodb_driver, "~> 1.0"},
    ]
  end
end
