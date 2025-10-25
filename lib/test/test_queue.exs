defmodule BimipLogTest do
  use ExUnit.Case
  alias BimipLog

  @user "test_user"
  @device "device1"
  @partition 1

  setup do
    # Clean up any previous test data
    File.rm_rf!("data/bimip/#{@user}")
    :ok
  end

  test "write and fetch messages across segments" do
    # Write 5 messages
    Enum.each(1..5, fn i ->
      {:ok, offset} = BimipLog.write(@user, @partition, "alice", "bob", "Hello #{i}")
      assert offset == i
    end)

    # Fetch messages for device
    {:ok, messages, next_offset} = BimipLog.fetch(@user, @device, @partition, 10)
    
    assert length(messages) == 5
    assert next_offset == 5

    # Check that content matches
    Enum.each(Enum.with_index(messages, 1), fn {msg, idx} ->
      assert msg.payload == "Hello #{idx}"
      assert msg.offset == idx
      assert msg.partition_id == @partition
      assert msg.from == "alice"
      assert msg.to == "bob"
    end)
  end

  test "segment rollover when size exceeds limit" do
    # Write messages until we force a segment rollover
    big_payload = :binary.copy("x", 1_000_000) # 1 MB payload
    {:ok, offset1} = BimipLog.write(@user, @partition, "alice", "bob", big_payload)
    {:ok, offset2} = BimipLog.write(@user, @partition, "alice", "bob", big_payload)

    # After writing 2 MB, the segment should roll over
    current_seg = BimipLog.get_current_segment(@user, @partition)
    assert current_seg >= 2
  end
end
