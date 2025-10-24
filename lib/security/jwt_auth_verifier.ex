defmodule Bimip.Auth.TokenVerifier do
  # Security: JWT verification using Joken and runtime config
  use Joken.Config
  require Logger
  alias Settings.Jwt

  # -------------------------------
  # Base Claims
  # -------------------------------
  def base_claims do
    default_claims(skip: [:aud])
    |> add_claim("device_id", nil, &is_binary/1)
    |> add_claim("eid", nil, &is_binary/1)
    |> add_claim("jti", fn -> System.unique_integer([:positive]) |> Integer.to_string() end, &is_binary/1)
    |> add_claim("type", nil, &(&1 in ["access", "refresh"]))
  end

  # -------------------------------
  # Load Public Key at Runtime
  # -------------------------------
  defp load_public_key do
    Jwt.public_key_path()
    |> File.read!()
    |> JOSE.JWK.from_pem()
    |> JOSE.JWK.to_map()
    |> elem(1)
  end

  # -------------------------------
  # JWT Signer (runtime-safe)
  # -------------------------------
  def verifier do
    Joken.Signer.create(Jwt.signing_algorithm(), load_public_key())
  end

  # -------------------------------
  # Token Extraction
  # -------------------------------
  def extract_token(nil), do: {:error, :invalid_token}
  def extract_token(""), do: {:error, :invalid_token}
  def extract_token("Bearer " <> token) when is_binary(token), do: {:ok, token}
  def extract_token(token) when is_binary(token), do: {:ok, token}

  # -------------------------------
  # Token Verification
  # -------------------------------
  def verify_token(token) do
    case verify_and_validate(token, verifier()) do
      {:ok, claims} ->
        if token_revoked?(claims["jti"]) do
          {:error, :token_invoked}
        else
          {:ok, claims}
        end

      {:error, _reason} ->
        {:error, :invalid_token}
    end
  end

  # -------------------------------
  # Token Revocation Check (stub)
  # -------------------------------
  def token_revoked?(_jti), do: false
end
