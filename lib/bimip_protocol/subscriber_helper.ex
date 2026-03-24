defmodule BimipSubscribers.Handler do
  require Logger

  @doc """
  Extracts eids from a Base64 Protobuf string.
  Returns a list of strings. If the input is tempered with or invalid,
  it returns an empty list [].
  """
  def extract_eids(nil), do: []
  def extract_eids(encoded_str) do
    with {:ok, binary} <- Base.decode64(encoded_str),
         {:ok, struct} <- safe_decode_protobuf(binary) do
      # Return only the list of eids
      struct.eid
    else
      _error ->
        # Log the failure for debugging, but return an empty list to the app
        Logger.debug("Subscriber extraction failed. Returning empty list.")
        []
    end
  end

  # Internal helper to catch Protobuf decoding crashes
  defp safe_decode_protobuf(binary) do
    {:ok, BimipSubscribers.Subcribers.decode(binary)}
  rescue
    _e -> {:error, :corrupt_protobuf}
  end
end
