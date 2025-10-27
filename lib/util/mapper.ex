defmodule Util.StatusMapper do
  def to_int(:online), do: 1
  def to_int(:offline), do: 4
  def to_int(_), do: nil  # fallback for unexpected atoms

  def map_status_to_code(status) do
    case String.upcase(to_string(status)) do
      "ONLINE" -> 1
      "OFFLINE" -> 2
      _ -> 0  # Unknown or unsupported
    end
  end
  
  def status_name(code) do
    case code do
      1 -> "ONLINE"
      2 -> "OFFLINE"
      3 -> "AWAY"
      4 -> "BUSY"
      5 -> "DND"
      6 -> "TYPING"
      7 -> "RECORDING"
      8 -> "FORWARDED"
      9 -> "DELIVERED"
      10 -> "READ"
      11 -> "RESUME"
      _ -> "UNKNOWN"
    end
  end

end





