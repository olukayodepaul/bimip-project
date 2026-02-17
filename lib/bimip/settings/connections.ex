defmodule Settings.Connections do
  @moduledoc """
  Helper module to read connections config at runtime.
  """

  @env Application.compile_env(:bimips, :connections, [])

  # TLS enabled?
  def secure_tls? do
    System.get_env("BIMIP_SECURE_TLS")
    |> parse_bool(@env[:secure_tls] || false)
  end

  # TLS port
  def tls_port do
    System.get_env("BIMIP_TLS_PORT")
    |> parse_int(@env[:tls_port] || 4001)
  end

  # Non-TLS port
  def clear_port do
    System.get_env("BIMIP_CLEAR_PORT")
    |> parse_int(@env[:clear_port] || 4000)
  end

  # Cert file path
  def cert_file do
    System.get_env("BIMIP_CERT_FILE") || @env[:cert_file] || "priv/keys/cert.pem"
  end

  # Key file path
  def key_file do
    System.get_env("BIMIP_KEY_FILE") || @env[:key_file] || "priv/keys/key.pem"
  end

  # Resource path
  def resource_path do
    System.get_env("BIMIP_RESOURCE_PATH") || @env[:resource_path] || "/application/development"
  end

  # Idle timeout
  def idle_timeout do
    System.get_env("BIMIP_IDLE_TIMEOUT")
    |> parse_int(@env[:idle_timeout] || 60_000)
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
