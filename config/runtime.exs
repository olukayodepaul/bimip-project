import Config

# -----------------------
# CONNECTIONS
# -----------------------
config :bimips, :connections,
  secure_tls: String.downcase(System.get_env("BIMIP_SECURE_TLS") || "false") == "true",
  tls_port: String.to_integer(System.get_env("BIMIP_TLS_PORT") || "4001"),
  clear_port: String.to_integer(System.get_env("BIMIP_CLEAR_PORT") || "4000"),
  cert_file: System.get_env("BIMIP_CERT_FILE") || "priv/cert.pem",
  key_file: System.get_env("BIMIP_KEY_FILE") || "priv/key.pem",
  resource_path: System.get_env("BIMIP_RESOURCE_PATH") || "/application/development",
  idle_timeout: String.to_integer(System.get_env("BIMIP_IDLE_TIMEOUT") || "60000"),
  stale_threshold_seconds: String.to_integer(System.get_env("BIMIP_SERVER_STALE_THRESHOLD_SECONDS") || "600")

# -----------------------
# JWT
# -----------------------
config :bimips, :jwt,
  public_key: System.get_env("BIMIP_PUBLIC_KEY") || "priv/keys/public.pem",
  signing_algorithm: System.get_env("BIMIP_SIGNING_ALGORITHM") || "RS256"
