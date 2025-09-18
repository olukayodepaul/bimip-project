defmodule Settings.Jwt do
  #settings
  @moduledoc """
  Provides access to JWT configuration for the Bimip application.
  """

  @config :bimip

  def public_key_path do
    get(:jwt) |> Keyword.get(:public_key_path, "priv/keys/default_public.pem")
  end

  def signing_algorithm do
    get(:jwt) |> Keyword.get(:signing_algorithm, "RS256")
  end

  defp get(key), do: Application.get_env(@config, key, [])
end
