import Config

# -------------------------------------------------------------------------
# 1. LOAD .ENV FILE
# -------------------------------------------------------------------------
dot_env_path = Path.expand(".env")

if File.exists?(dot_env_path) do
  dot_env_path
  |> File.stream!()
  |> Enum.map(&String.trim/1)
  |> Enum.filter(&(String.length(&1) > 0 and not String.starts_with?(&1, "#")))
  |> Enum.each(fn line ->
    case String.split(line, "=", parts: 2) do
      [key, value] -> System.put_env(String.trim(key), String.trim(value))
      _ -> :ok
    end
  end)
end

# -------------------------------------------------------------------------
# 2. PRE-CONFIG CALCULATIONS & CONSTANTS
# -------------------------------------------------------------------------
# Internal Law: Sparse index stride is hardcoded to ensure data integrity.
internal_stride = String.to_integer(System.get_env("BIMIP_STORAGE_STRIDE") || "1000")

retention_days = String.to_integer(System.get_env("BIMIP_LIFECYCLE_RETENTION_DAYS") || "1")
max_seg = String.to_integer(System.get_env("BIMIP_STORAGE_MAX_SEGMENT_MESSAGES") || "1000000")
flush_secs = String.to_integer(System.get_env("BIMIP_FLUSH_INTERVAL_SECONDS") || "10")

# Validation: Ensure segment size aligns with the internal index stride
if rem(max_seg, internal_stride) != 0 do
  raise ArgumentError, "BIMIP_STORAGE_MAX_SEGMENT_MESSAGES must be a multiple of #{internal_stride}."
end

# -------------------------------------------------------------------------
# 3. NETWORK & TLS CONFIGURATION
# -------------------------------------------------------------------------
config :bimips, :connections,
  secure_tls: String.downcase(System.get_env("BIMIP_SECURE_TLS")) == "true",
  tls_port: String.to_integer(System.get_env("BIMIP_PORT_TLS") || "4001"),
  cert_file: System.get_env("BIMIP_SSL_CERT_PATH") || "priv/cert/selfsigned.pem",
  key_file: System.get_env("BIMIP_SSL_KEY_PATH") || "priv/cert/selfsigned_key.pem",
  resource_path: System.get_env("BIMIP_RESOURCE_PATH") || "/",
  clear_port: String.to_integer(System.get_env("BIMIP_NONE_TLS_PORT") || "4000"),
  stale_threshold_seconds: String.to_integer(System.get_env("BIMIP_DEVICE_STALE_THRESHOLD_SECONDS") || 600)



# -------------------------------------------------------------------------
# 4. QUEUE & PERFORMANCE CONFIGURATION
# -------------------------------------------------------------------------
config :bimips, :queue,
  max_batch_size: String.to_integer(System.get_env("BIMIP_QUEUE_MAX_BATCH_SIZE") || "100"),
  compact_interval: String.to_integer(System.get_env("BIMIP_STORAGE_COMPACT_INTERVAL_HOURS") || "4"),
  archive_root: System.get_env("BIMIP_STORAGE_ARCHIVE_ROOT") || "data/archive",
  max_read_fds: String.to_integer(System.get_env("BIMIP_STORAGE_MAX_READ_FDS") || "11"),
  retention_seconds: retention_days * 86_400,
  stable_limit: String.to_integer(System.get_env("BIMIP_QUEUE_STABLE_LIMIT") || "1000"),
  max_buffer_per_shard: String.to_integer(System.get_env("BIMIP_QUEUE_MAX_BUFFER_PER_SHARD") || "10000000"),
  user_stride: internal_stride,
  max_messages_per_seg: max_seg,
  flush_interval_ms: flush_secs * 1_000


# -------------------------------------------------------------------------
# 5. SECURITY & AUTHENTICATION
# -------------------------------------------------------------------------
# Path.expand/1 turns "./priv/keys/public.pem" into a full absolute path
# based on the project root during compilation.

config :bimips, :auth,
  public_key_path: System.get_env("BIMIP_JWT_PUBLIC_KEY_PATH") || "priv/keys/public.pem",
  signing_algorithm: System.get_env("BIMIP_JWT_ALGORITHM") || "RS256"


config :bimips, :network,

  max_idle_ms: String.to_integer(System.get_env("BIMIP_HEARTBEAT_DEVICE_STALE_SEC") || "600") * 1_000,

  # Heartbeat for federation/reporting
  report_interval_ms: String.to_integer(System.get_env("BIMIP_HEARTBEAT_REPORT_MS") || "60000"),


  # From your .env: BIMIP_DEFAULT_PING_INTERVAL_MS (10000)
  ping_interval_ms: String.to_integer(System.get_env("BIMIP_DEFAULT_PING_INTERVAL_MS") || "10000"),

  # Absolute silence before we start worrying (BIMIP_HEARTBEAT_MAX_SILENCE_MS)
  max_silence_ms: String.to_integer(System.get_env("BIMIP_HEARTBEAT_MAX_SILENCE_MS") || "5000"),


  idle_timeout: String.to_integer(System.get_env("BIMIP_NETWORK_IDLE_TIMEOUT_MS") || "60000"),

  # Adaptive Network Settings
  rtt_thresholds: %{high: 500, low: 100},

  ping_intervals: %{high_rtt: 20_000, medium_rtt: 15_000, default: 10_000},

  max_missed_pongs: %{high: 8, low: 3, default: 5},

  reply_window: String.to_integer(System.get_env("BIMIP_VALIDATOR_REPLAY_WINDOW_MS") || "30000"),

  future_tolerance: String.to_integer(System.get_env("BIMIP_VALIDATOR_CLOCK_FUTURE_TOLERANCE_MS") || "10000"),

  flow_rate_limit: String.to_integer(System.get_env("BIMIP_FLOW_STANZA_RATE_LIMIT_MS") || "5000")


# -------------------------------------------------------------------------
# 6. PUSH NOTIFICATION CONFIGURATION (PIGEON)
# -------------------------------------------------------------------------

# --- APNS (Apple Push Notification Service) ---
# Note: You typically use EITHER a certificate (.pem) OR a token (.p8).
config :pigeon, :apns,
  apns_default: %{
    # Option A: Certs
    cert: System.get_env("BIMIP_APNS_CERT_PATH"),
    key: System.get_env("BIMIP_APNS_KEY_PATH"),

    # Option B: Tokens (Will be nil if commented out in .env)
    key_id: System.get_env("BIMIP_APNS_KEY_ID"),
    team_id: System.get_env("BIMIP_APNS_TEAM_ID"),
    p8_file: System.get_env("BIMIP_APNS_P8_PATH"),

    mode: String.to_atom(System.get_env("BIMIP_APNS_MODE") || "dev")
  }

# --- FCM (Firebase Cloud Messaging for Android) ---
# config/config.exs

config :pigeon, :fcm_default,
  adapter: Pigeon.FCM,
  service_account_json: System.get_env("BIMIP_FCM_SERVICE_ACCOUNT_PATH") || "priv/fcm/service_account.json"
