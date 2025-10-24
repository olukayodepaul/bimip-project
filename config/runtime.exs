import Config

# --- Connection config ---
config :bimip, :connections,
  secure_tls: String.to_atom(System.get_env("BIMIP_SECURE_TLS") || "false"),
  cert_file: System.get_env("BIMIP_CERT_FILE") || "priv/cert.pem",
  key_file: System.get_env("BIMIP_KEY_FILE") || "priv/key.pem",
  port: String.to_integer(System.get_env("BIMIP_PORT") || "4001"),
  resource_path: System.get_env("BIMIP_RESOURCE_PATH") || "/application/development",
  idle_timeout: String.to_integer(System.get_env("BIMIP_IDLE_TIMEOUT") || "60000")

# --- PubSub topic ---
config :bimip, :subpub,
  topic: String.to_atom(System.get_env("BIMIP_TOPIC") || "default")

# --- JWT / Key configuration ---
config :bimip, :jwt,
  public_key_path: System.get_env("BIMIP_PUBLIC_KEY_PATH") || "/etc/bimip/keys/public.pem",
  signing_algorithm: System.get_env("BIMIP_SIGNING_ALG") || "RS256"

# --- Adaptive Ping/Pong ---
config :bimip, :adaptive_network_ping_pong,
  default_ping_interval_ms: String.to_integer(System.get_env("BIMIP_PING_INTERVAL") || "10000"),
  max_allowed_delay_seconds: String.to_integer(System.get_env("BIMIP_MAX_DELAY") || "120"),
  max_pong_retries: String.to_integer(System.get_env("BIMIP_PONG_RETRIES") || "3"),
  initial_max_missed_pings: String.to_integer(System.get_env("BIMIP_MAX_MISSED_PINGS") || "6"),
  rtt_thresholds: %{high: 500, low: 100},
  ping_intervals: %{high_rtt: 2000, medium_rtt: 1000, default: 1000},
  max_missed_pongs: %{high: 8, low: 3, default: 5}

# --- Device State Change ---
config :bimip, :device_state_change,
  stale_threshold_seconds: String.to_integer(System.get_env("BIMIP_DEVICE_STALE") || "600"),
  force_change_seconds: String.to_integer(System.get_env("BIMIP_DEVICE_FORCE_CHANGE") || "300")

# --- Server State Change ---
config :bimip, :server_state,
  stale_threshold_seconds: String.to_integer(System.get_env("BIMIP_SERVER_STALE") || "600"),
  force_change_seconds: String.to_integer(System.get_env("BIMIP_SERVER_FORCE_CHANGE") || "120")

# --- Queue ---
config :bimip, :queue,
  max_queue_size: String.to_integer(System.get_env("BIMIP_MAX_QUEUE") || "1000")
