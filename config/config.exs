import Config

config :bimip, :connections,
  secure_tls: false, 
  cert_file: "priv/cert.pem",
  key_file: "priv/key.pem",
  port: 4001,
  resource_path: "/application/development",
  idle_timeout: 60_000

config :bimip, :subpub,
  topic: :default

config :bimip, :jwt,
  public_key_path: "priv/keys/public.pem",
  signing_algorithm: "RS256"

config :bimip, :adaptive_network_ping_pong,
  default_ping_interval_ms: 10_000,     # Ping every 10s → light but responsive
  max_allowed_delay_seconds: 60 * 2,    # Allow up to 45s delay before forcing check
  max_pong_retries: 5,                  # Refresh ONLINE every ~30s (3 × 10s)
  initial_max_missed_pings: 6,          # 6 misses = ~60s silence → OFFLINE

  # Adaptive tuning
  rtt_thresholds: %{high: 500, low: 100},         # RTT thresholds in ms
  ping_intervals: %{high_rtt: 2_000, medium_rtt: 1_000, default: 1_000},
  max_missed_pongs: %{high: 8, low: 3, default: 5}

config :bimip, :device_state_change,
  stale_threshold_seconds: 60 * 10,   # Device considered stale after 2 min without pong
  force_change_seconds: 60 * 5    # Force a rebroadcast every 1 min idle

config :bimip, :server_state,
  stale_threshold_seconds: 60 * 10,   # 60 * 20 User considered stale after 10 min no device activity
  force_change_seconds: 60 * 2       # Force rebroadcast every 5 min idle

config :bimip, :queue,
  max_queue_size: 1000
