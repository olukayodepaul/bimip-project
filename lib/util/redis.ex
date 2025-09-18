defmodule Util.TokenRevoked do
  #util
  require Logger

  def store_revocation(jti, exp) do
    ttl = exp - System.os_time(:second)

    if ttl > 0 do
      value = %{jti: jti, exp: exp}

      # Save in Redis with TTL
      Redix.pipeline!(:redix, [
        ["SETEX", "revoked:#{jti}", ttl, Jason.encode!(value)]
      ])
    end

    :ok
  end

  def revoked?(jti) do

    case Redix.command!(:redix, ["EXISTS", "revoked:#{jti}"]) do
      1 -> true
      0 -> false
    end
  end

end

#redis-cli
#KEYS revoked:*
#GET revoked:31hgn2glfr71f94ke4000221