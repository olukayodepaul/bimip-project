import Config

# -----------------------
# SUBPUB
# -----------------------
config :bimips, :subpub,
  topic: :default

# -----------------------
# JWT (static defaults, can be overridden in runtime.exs)
# -----------------------
config :bimips, :jwt,
  public_key_path: "priv/keys/public.pem",
  signing_algorithm: "RS256"

# -----------------------
# Adaptive network ping/pong
# -----------------------
config :bimips, :adaptive_network_ping_pong,
  default_ping_interval_ms: 10_000,
  max_allowed_delay_seconds: 60 * 2,
  max_pong_retries: 5,
  initial_max_missed_pings: 6,
  rtt_thresholds: %{high: 500, low: 100},
  ping_intervals: %{high_rtt: 2_000, medium_rtt: 1_000, default: 1_000},
  max_missed_pongs: %{high: 8, low: 3, default: 5}

# -----------------------
# Device & server state change defaults
# -----------------------
config :bimips, :device_state_change,
  stale_threshold_seconds: 60 * 10,
  force_change_seconds: 60 * 5

config :bimips, :server_state,
  stale_threshold_seconds: 60 * 10,
  force_change_seconds: 60 * 2

# -----------------------
# Queue
# -----------------------
config :bimips, :queue,
  max_queue_size: 1000

# -----------------------
# General
# -----------------------
config :bimips,
  num_shards: 64
