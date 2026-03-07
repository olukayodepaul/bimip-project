defmodule Settings.Connections do
  @moduledoc """
  Helper module to read runtime config for connections and JWT.
  """

  # -----------------------
  # Connection Settings
  # -----------------------

  # TLS enabled?
  def secure_tls? do
    System.get_env("BIMIP_SECURE_TLS")
    |> parse_bool(Application.get_env(:bimips, :connections, [])[:secure_tls] || false)
  end

  # TLS port
  def tls_port do
    System.get_env("BIMIP_TLS_PORT")
    |> parse_int(Application.get_env(:bimips, :connections, [])[:tls_port] || 4001)
  end

  # Non-TLS port
  def clear_port do
    System.get_env("BIMIP_CLEAR_PORT")
    |> parse_int(Application.get_env(:bimips, :connections, [])[:clear_port] || 4000)
  end

  # Cert file path
  def cert_file do
    System.get_env("BIMIP_CERT_FILE") ||
      Application.get_env(:bimips, :connections, [])[:cert_file] ||
      "priv/keys/cert.pem"
  end

  def stale_threshold_seconds do
    System.get_env("BIMIP_SERVER_STALE_THRESHOLD_SECONDS") ||
    Application.get_env(:bimips, :connections, [])[:stale_threshold_seconds] || 1
  end

  # Key file path
  def key_file do
    System.get_env("BIMIP_KEY_FILE") ||
      Application.get_env(:bimips, :connections, [])[:key_file] ||
      "priv/keys/key.pem"
  end

  # Resource path
  def resource_path do
    System.get_env("BIMIP_RESOURCE_PATH") ||
      Application.get_env(:bimips, :connections, [])[:resource_path] ||
      "/application/development"
  end

  # Idle timeout
  def idle_timeout do
    System.get_env("BIMIP_IDLE_TIMEOUT")
    |> parse_int(Application.get_env(:bimips, :connections, [])[:idle_timeout] || 60_000)
  end

  # -----------------------
  # JWT Settings
  # -----------------------

  # Public key path
  def jwt_public_key do
    System.get_env("BIMIP_PUBLIC_KEY") ||
      Application.get_env(:bimips, :jwt, [])[:public_key] ||
      "./priv/keys/public.pem"
  end

  # Signing algorithm
  def jwt_signing_algorithm do
    System.get_env("BIMIP_SIGNING_ALGORITHM") ||
      Application.get_env(:bimips, :jwt, [])[:signing_algorithm] ||
      "RS256"
  end

  # -----------------------
  # Private helpers
  # -----------------------
  defp parse_bool(nil, default), do: default
  defp parse_bool(val, _default) when is_binary(val), do: String.downcase(val) == "true"
  defp parse_int(nil, default), do: default
  defp parse_int(val, _default) when is_binary(val), do: String.to_integer(val)
  defp parse_int(val, _default) when is_integer(val), do: val
end
