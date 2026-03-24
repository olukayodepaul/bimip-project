defmodule Application.Config do
  @moduledoc """
  Helper module to read runtime config for connections, queue, and security.
  """

  # -----------------------
  # Section 1: Connection Settings
  # -----------------------

  def resource_path do
    System.get_env("BIMIP_RESOURCE_PATH") ||
      Application.get_env(:bimips, :connections, [])[:resource_path] ||
      "/"
  end

  def clear_port do
    System.get_env("BIMIP_NONE_TLS_PORT")
    |> parse_int(Application.get_env(:bimips, :connections, [])[:clear_port] || 4000)
  end

  def idle_timeout do
    System.get_env("BIMIP_NETWORK_IDLE_TIMEOUT_MS")
    |> parse_int(Application.get_env(:bimips, :connections, [])[:idle_timeout] || 60_000)
  end

  def stale_threshold_seconds do
    System.get_env("BIMIP_DEVICE_STALE_THRESHOLD_SECONDS")
    |> parse_int(Application.get_env(:bimips, :connections, [])[:stale_threshold_seconds] || 600)
  end


  # -----------------------
  # Section 2: Security & TLS
  # -----------------------

  def secure_tls? do
    System.get_env("BIMIP_SECURE_TLS")
    |> parse_bool(Application.get_env(:bimips, :connections, [])[:secure_tls] || false)
  end

  def tls_port do
    System.get_env("BIMIP_PORT_TLS")
    |> parse_int(Application.get_env(:bimips, :connections, [])[:tls_port] || 4001)
  end

  def cert_file do
    System.get_env("BIMIP_SSL_CERT_PATH") ||
      Application.get_env(:bimips, :connections, [])[:cert_file] ||
      "./priv/cert/selfsigned.pem"
  end

  def key_file do
    System.get_env("BIMIP_SSL_KEY_PATH") ||
      Application.get_env(:bimips, :connections, [])[:key_file] ||
      "./priv/cert/selfsigned_key.pem"
  end

  def jwt_public_key do
    System.get_env("BIMIP_JWT_PUBLIC_KEY_PATH") ||
      Application.get_env(:bimips, :auth, [])[:public_key_path] ||
      "priv/keys/public.pem"
  end

  def jwt_signing_algorithm do
    System.get_env("BIMIP_JWT_ALGORITHM") ||
      Application.get_env(:bimips, :auth, [])[:signing_algorithm] ||
      "RS256"
  end


  # -----------------------
  # Section 3 & 4: Queue & Storage
  # -----------------------

  def queue_num_shards do
    System.get_env("BIMIP_QUEUE_NUM_SHARDS")
    |> parse_int(Application.get_env(:bimips, :queue, [])[:num_shards] || 16)
  end

  def max_batch_size do
    System.get_env("BIMIP_QUEUE_MAX_BATCH_SIZE")
    |> parse_int(Application.get_env(:bimips, :queue, [])[:max_batch_size] || 100)
  end

  def archive_root do
    System.get_env("BIMIP_STORAGE_ARCHIVE_ROOT") ||
      Application.get_env(:bimips, :queue, [])[:archive_root] ||
      "data/archive"
  end

  def compact_interval_hours do
    System.get_env("BIMIP_STORAGE_COMPACT_INTERVAL_HOURS")
    |> parse_int(Application.get_env(:bimips, :queue, [])[:compact_interval] || 4)
  end

  def max_read_fds do
    System.get_env("BIMIP_STORAGE_MAX_READ_FDS")
    |> parse_int(Application.get_env(:bimips, :queue, [])[:max_read_fds] || 11)
  end

  def flush_interval_ms do
    System.get_env("BIMIP_FLUSH_INTERVAL_SECONDS")
    |> parse_int(Application.get_env(:bimips, :queue, [])[:flush_interval_ms] || 10)
  end

  def max_messages_per_seg do
    System.get_env("BIMIP_STORAGE_MAX_SEGMENT_MESSAGES")
    |> parse_int(Application.get_env(:bimips, :queue, [])[:max_messages_per_seg] || 10)
  end

  def user_stride do
    System.get_env("BIMIP_STORAGE_STRIDE")
    |> parse_int(Application.get_env(:bimips, :queue, [])[:user_stride] || 1000)
  end

  def retention_seconds do
    System.get_env("BIMIP_LIFECYCLE_RETENTION_DAYS")
    |> parse_int(Application.get_env(:bimips, :queue, [])[:retention_seconds] || 1)
  end

  def max_buffer_per_shard do
    System.get_env("BIMIP_QUEUE_MAX_BUFFER_PER_SHARD")
    |> parse_int(Application.get_env(:bimips, :queue, [])[:max_buffer_per_shard] || 10000000)
  end

  def stable_limit do
    System.get_env("BIMIP_QUEUE_STABLE_LIMIT")
    |> parse_int(Application.get_env(:bimips, :queue, [])[:stable_limit] || 1000)
  end

  # -----------------------
  # Section 6: Monitoring & Heartbeats
  # -----------------------

  def report_interval_ms do
    System.get_env("BIMIP_HEARTBEAT_REPORT_MS")
    |> parse_int(Application.get_env(:bimips, :network, [])[:report_interval_ms] || 60000)
  end

  def max_idle_ms do
    System.get_env("BIMIP_HEARTBEAT_DEVICE_STALE_SEC")
    |> parse_int(600)
    |> Kernel.*(1_000)
  end

  def max_batch_size do
    System.get_env("BIMIP_QUEUE_MAX_BATCH_SIZE")
    |> parse_int(Application.get_env(:bimips, :queue, [])[:max_batch_size] || 100)
  end

  def max_silence_ms do
    System.get_env("BIMIP_HEARTBEAT_MAX_SILENCE_MS")
    |> parse_int(Application.get_env(:bimips, :network, [])[:max_silence_ms] || 5000)
  end

  # Idle timeout
  def idle_timeout do
    System.get_env("BIMIP_NETWORK_IDLE_TIMEOUT_MS")
    |> parse_int(Application.get_env(:bimips, :network, [])[:idle_timeout] || 60_000)
  end

  # Idle timeout
  def reply_window do
    System.get_env("BIMIP_VALIDATOR_REPLAY_WINDOW_MS")
    |> parse_int(Application.get_env(:bimips, :network, [])[:reply_window] || 30000)
  end

  # Idle timeout
  def future_tolerance do
    System.get_env("BIMIP_VALIDATOR_CLOCK_FUTURE_TOLERANCE_MS")
    |> parse_int(Application.get_env(:bimips, :network, [])[:future_tolerance] || 10000)
  end

  # Idle timeout
  def flow_rate_limit do
    System.get_env("BIMIP_FLOW_STANZA_RATE_LIMIT_MS")
    |> parse_int(Application.get_env(:bimips, :network, [])[:flow_rate_limit] || 5000)
  end

  # Adaptive Network Logic
  def default_ping_interval_ms, do: get_network(:ping_interval_ms, 10_000)
  def rtt_thresholds, do: get_network(:rtt_thresholds, %{high: 500, low: 100})
  def ping_intervals, do: get_network(:ping_intervals, %{high_rtt: 20_000, medium_rtt: 15_000, default: 10_000})
  def max_missed_pongs, do: get_network(:max_missed_pongs, %{high: 8, low: 3, default: 5})


  # -----------------------
  # Private helpers
  # -----------------------

  defp get_network(key, default) do
    Application.get_env(:bimips, :network, [])
    |> Keyword.get(key, default)
  end

  defp parse_bool(nil, default), do: default
  defp parse_bool(val, _default) when is_binary(val), do: String.downcase(val) == "true"
  defp parse_bool(val, _default) when is_boolean(val), do: val

  defp parse_int(nil, default), do: default
  defp parse_int(val, _default) when is_binary(val) do
    case Integer.parse(val) do
      {int, _} -> int
      :error -> _default
    end
  end
  defp parse_int(val, _default) when is_integer(val), do: val
end
