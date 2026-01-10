defmodule Queue.QueueLogTest do
  alias Queue.QueueLogImpl
  require Logger

  @doc """
  Runs a full write-and-read cycle with complex nested payloads.
  """
  def test_full_cycle do
    IO.puts("\n=== STARTING BIMIP v6 PAYLOAD INTEGRITY TEST ===")

    # 1. Write data to all 64 shards
    user_results = run_writes()

    # 2. Wait for the background flush (disk commit)
    IO.puts("\n>>> Waiting 250ms for fsync...")
    Process.sleep(250)

    # 3. Fetch and verify the nested structure
    IO.puts(">>> Verifying data integrity...")
    verify_data(user_results)

    IO.puts("\n=== TEST PASSED ===")
  end
def run_writes do
  IO.puts(">>> Writing 64 messages (one per shard)...")

  Enum.map(0..63, fn i ->
    user = "user_#{i}"

    # 1. This is the "inner" data that your Bimip.Message struct needs
    inner_payload = %{
      peer_uid: "peer_#{i}",
      from: %{eid: user, connection_resource_id: "res_#{i}"},
      to: %{eid: "user_#{i}_target", connection_resource_id: "res_#{i}_target"},
      payload: "Hello from shard #{i}",
      encryption_type: nil,
      encrypted: false,
      signature: nil
    }

    # 2. WRAP IT: Persist.build/5 expects %{payload: ...}
    attrs = %{payload: inner_payload}

    # 3. Pass 'attrs' as the 6th argument to write/7
    case Queue.QueueLogImpl.write(1, user, "reply_to", :text, %{ctx: "test"}, attrs, "msg_#{i}") do
      {:ok, offset} ->
        IO.write(".")
        {user, offset, attrs} # Store 'attrs' to verify later
      error ->
        IO.puts("\n[!] Write failed: #{inspect(error)}")
        {user, nil, nil}
    end
  end)
end

 def verify_data(results) do
  Enum.each(results, fn {user, offset, original_attrs} ->
    case Queue.QueueLogImpl.fetch(user, 1, offset) do
      {:ok, %Bimip.Message{} = stored_msg} ->
        # The 'original_attrs.payload.payload' is the string "Hello from shard X"
        expected_string = original_attrs.payload.payload

        if stored_msg.payload == expected_string do
          :ok
        else
          IO.puts("\n[!] Data mismatch for #{user}!")
          IO.inspect(stored_msg.payload, label: "Stored String")
          IO.inspect(expected_string, label: "Expected String")
          exit(:data_mismatch)
        end

      {:ok, other} ->
        IO.puts("\n[!] Unexpected data type returned: #{inspect(other)}")
        exit(:wrong_data_type)

      {:error, reason} ->
        IO.puts("\n[!] Could not fetch data for #{user}: #{inspect(reason)}")
        exit(:fetch_failed)
    end
  end)
  IO.puts("\n>>> All 64 shards verified. Strings matched inside Bimip.Message structs.")
end
end
