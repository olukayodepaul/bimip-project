defmodule Util.StatusMapper do
  def to_int(:online), do: 1
  def to_int(:offline), do: 4
  def to_int(_), do: nil  # fallback for unexpected atoms
end

