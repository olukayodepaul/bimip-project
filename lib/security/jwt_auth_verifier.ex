defmodule Bimip.Auth.TokenVerifier do
  @moduledoc """
  Handles token verification with detailed internal logging but safe external returns.
  """
  use Joken.Config
  require Logger
  alias Settings.Connections

  # --- Key Loading ---

  defp load_public_key do
    path = Connections.jwt_public_key()

    with {:ok, binary} <- File.read(path),
         {:ok, jwk} <- safe_decode_pem(binary) do
      {_type, key_map} = JOSE.JWK.to_map(jwk)
      key_map
    else
      {:error, reason} ->
        Logger.error("JWT Public Key Error [File/PEM]: #{inspect(reason)}")
        nil
    end
  end

  defp safe_decode_pem(binary) do
    {:ok, JOSE.JWK.from_pem(binary)}
  rescue
    _e -> {:error, :corrupt_pem_format}
  end

  def get_signer do
    algo = Connections.jwt_signing_algorithm()

    case load_public_key() do
      nil -> {:error, :key_not_available}
      key_map ->
        try do
          {:ok, Joken.Signer.create(algo, key_map)}
        rescue
          e ->
            Logger.error("Joken Signer Creation Failed: #{inspect(e)}")
            {:error, :invalid_key_structure}
        end
    end
  end

  # --- Verification Logic ---

  def verify_token(token) do
    case get_signer() do
      {:ok, signer} ->
        case verify_and_validate(token, signer) do
          {:ok, claims} ->
            {:ok, claims}
          {:error, reason} ->
            # Returns the specific Joken reason (e.g., "Invalid signature", "Token expired")
            {:error, "Token validation failed: #{inspect(reason)}"}
        end

      {:error, :invalid_key_structure } ->
        {:error, "Internal System Error: The public key file is missing or unreadable."}

      {:error, :key_not_available} ->
        {:error, "Internal System Error: The public key is malformed or tempered with."}

      {:error, _} ->
        {:error, "Internal System Error: An unexpected security configuration error occurred."}
    end
  end

  def verify_from_header("Bearer " <> token), do: verify_token(token)
  def verify_from_header(token) when is_binary(token), do: verify_token(token)
  def verify_from_header(_), do: {:error, :invalid_header}
end
