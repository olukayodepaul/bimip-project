
defmodule Bimip.Auth.TokenVerifier do
  #security

  use Joken.Config
  require Logger
  alias Settings.Jwt

  @public_key_path Jwt.public_key_path()
  @sign_alg Jwt.signing_algorithm()

  def base_claims do
    default_claims(skip: [:aud])
    |> add_claim("device_id", nil, &is_binary/1)
    |> add_claim("eid", nil, &is_binary/1)
    |> add_claim("jti", fn -> System.unique_integer([:positive]) |> Integer.to_string() end, &is_binary/1)
    |> add_claim("type", nil, &(&1 in ["access", "refresh"]))
  end

  defp load_public_key do
    File.read!(@public_key_path)
    |> JOSE.JWK.from_pem()
    |> JOSE.JWK.to_map()
    |> elem(1)
  end

  def verifier do
    Joken.Signer.create(@sign_alg, load_public_key())
  end

  def extract_token(nil) do
    {:error, :invalid_token}
  end

  def extract_token("") do
    {:error, :invalid_token}
  end

  def extract_token("Bearer " <> token) when is_binary(token), do: {:ok, token}
  def extract_token(token) when is_binary(token), do: {:ok, token}

  def verify_token(token) do
    case verify_and_validate(token, verifier()) do
      {:ok, claims} ->
        if token_revoked?(claims["jti"]) do
          {:error, :token_invoked}
        else
          {:ok, claims}
        end

      {:error, _reason} ->
        {:reason, :invalid_token}
    end
  end

  def token_revoked?(_jti), do: false
end

