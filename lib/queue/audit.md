To truly see "under the hood" of a sharded Elixir system, you need to check three layers: **Process Health**, **Memory (ETS) State**, and **Physical Disk State**.

Here is the "Swiss Army Knife" of diagnostic commands you can run in your `iex` console to see exactly what is going on:

### 1. The Disk Layer (Physical Files)

This tells you if the files are physically being created and if the compactor is doing its job.

```elixir
# Total file count (as you used)
File.ls!("data/bimip") |> Enum.count()

# Check for "abandoned" temp files or quarantine files
File.ls!("data/bimip") |> Enum.filter(&String.contains?(&1, ".tmp"))

# Check the size of a specific shard's data (e.g., Shard 0)
File.stat!("data/bimip/shard_0_1.log").size / 1024 # Size in KB

```

---

### 2. The Memory Layer (ETS Tables)

This is where your "Real-Time" data lives before it hits the disk.

```elixir
# Check how many messages are currently sitting in ALL 64 buffers (waiting to be flushed)
0..63 
|> Enum.map(fn s -> :ets.info(:"bimip_buf_#{s}", :size) end) 
|> Enum.sum()

# Look at the last 5 messages written to a specific shard (Shard 10)
:ets.tab2list(:bimip_buf_10) |> Enum.take(-5)

# Check the 'User Offsets' table (The global counter for message IDs)
:ets.info(:bimip_user_offsets, :size)

```

---

### 3. The Process Layer (The Workers)

This tells you if any of your 64 shards have crashed or restarted recently.

```elixir
# Get a list of all Shard PIDs and their current memory usage
for s <- 0..63 do
  pid = Process.whereis(:"bimip_shard_#{s}")
  memory = Process.info(pid, :memory) |> elem(1)
  {:"shard_#{s}", pid, "#{div(memory, 1024)} KB"}
end

# Check the message queue of the Compactor 
# (If this is > 0, the compactor is struggling to keep up)
Process.info(Process.whereis(Queue.BimipCompactor), :message_queue_len)

```

---

### 4. The Registry Layer (Connection Pool)

This verifies that your File Descriptors are correctly mapped to your shards.

```elixir
# List all active File Descriptor workers
Registry.select(Queue.FDPoolRegistry, [{{:"$1", :"$2", :"$3"}, [], [{{:"$1", :"$2"}}]}])

```

---

### 5. The "Full Audit" (Copy-Paste)

Run this block to get a high-level summary of the entire system's state:

```elixir
IO.puts "--- BIMIP SYSTEM AUDIT ---"
IO.puts "Total Log Files: #{File.ls!("data/bimip") |> Enum.count()}"
IO.puts "Total Shards Alive: #{Supervisor.which_children(Queue.BimipSupervisor) |> length()}"
IO.puts "Total Bookmarks Saved: #{0..63 |> Enum.map(fn s -> :ets.info(:"device_bookmarks_cache_#{s}", :size) end) |> Enum.sum()}"
IO.puts "Registry Capacity: #{Registry.count(Queue.FDPoolRegistry)}/64"
IO.puts "--------------------------"

```

**Would you like me to wrap these commands into a `Queue.Diagnostics` module so you can just type `Queue.Diagnostics.run()`?**To truly see "under the hood" of a sharded Elixir system, you need to check three layers: **Process Health**, **Memory (ETS) State**, and **Physical Disk State**.

Here is the "Swiss Army Knife" of diagnostic commands you can run in your `iex` console to see exactly what is going on:

### 1. The Disk Layer (Physical Files)

This tells you if the files are physically being created and if the compactor is doing its job.

```elixir
# Total file count (as you used)
File.ls!("data/bimip") |> Enum.count()

# Check for "abandoned" temp files or quarantine files
File.ls!("data/bimip") |> Enum.filter(&String.contains?(&1, ".tmp"))

# Check the size of a specific shard's data (e.g., Shard 0)
File.stat!("data/bimip/shard_0_1.log").size / 1024 # Size in KB

```

---

### 2. The Memory Layer (ETS Tables)

This is where your "Real-Time" data lives before it hits the disk.

```elixir
# Check how many messages are currently sitting in ALL 64 buffers (waiting to be flushed)
0..63 
|> Enum.map(fn s -> :ets.info(:"bimip_buf_#{s}", :size) end) 
|> Enum.sum()

# Look at the last 5 messages written to a specific shard (Shard 10)
:ets.tab2list(:bimip_buf_10) |> Enum.take(-5)

# Check the 'User Offsets' table (The global counter for message IDs)
:ets.info(:bimip_user_offsets, :size)

```

---

### 3. The Process Layer (The Workers)

This tells you if any of your 64 shards have crashed or restarted recently.

```elixir
# Get a list of all Shard PIDs and their current memory usage
for s <- 0..63 do
  pid = Process.whereis(:"bimip_shard_#{s}")
  memory = Process.info(pid, :memory) |> elem(1)
  {:"shard_#{s}", pid, "#{div(memory, 1024)} KB"}
end

# Check the message queue of the Compactor 
# (If this is > 0, the compactor is struggling to keep up)
Process.info(Process.whereis(Queue.BimipCompactor), :message_queue_len)

```

---

### 4. The Registry Layer (Connection Pool)

This verifies that your File Descriptors are correctly mapped to your shards.

```elixir
# List all active File Descriptor workers
Registry.select(Queue.FDPoolRegistry, [{{:"$1", :"$2", :"$3"}, [], [{{:"$1", :"$2"}}]}])

```

---

### 5. The "Full Audit" (Copy-Paste)

Run this block to get a high-level summary of the entire system's state:

```elixir
IO.puts "--- BIMIP SYSTEM AUDIT ---"
IO.puts "Total Log Files: #{File.ls!("data/bimip") |> Enum.count()}"
IO.puts "Total Shards Alive: #{Supervisor.which_children(Queue.BimipSupervisor) |> length()}"
IO.puts "Total Bookmarks Saved: #{0..63 |> Enum.map(fn s -> :ets.info(:"device_bookmarks_cache_#{s}", :size) end) |> Enum.sum()}"
IO.puts "Registry Capacity: #{Registry.count(Queue.FDPoolRegistry)}/64"
IO.puts "--------------------------"

```

**Would you like me to wrap these commands into a `Queue.Diagnostics` module so you can just type `Queue.Diagnostics.run()`?**




# 1. Prepare the exact data
user = "a@domain.com"
msg_struct = %Chat.MessageStruct{
   peer_uid: "vcNAQcDoIIB4TCCAd0CAQAxggE2MIIBMgI",
   timestamp: 1767866248036,
   payload: "\"This is the test message 👋\"",
   payload_context: 1,
   encryption_type: "E2E",
   encrypted: "MIIB8AYJKoZIhvcNAQcDoIIB4TCCAd0CAQAxggE2MIIBMgIBADAfMA4GCSqGSIb3DQEBCwUwggExBgsqhkiG9w0BCwEw",
   signature: "SHA256-R4f0S4E3V7gH6tK2mP9Yc0B1dZ2eG3h4iJ5kL7o9pQ8rT6uV5wX4yZ3aBcD1fG0hI7jKmNlOpZqRsT",
   device_id: "aaaaa1",
   uupid: "1",
   eid: "a@domain.com",
   from: %Chat.EntityStruct{eid: "a@domain.com", connection_resource_id: "aaaaa1"},
   to: %Chat.EntityStruct{eid: "b@domain.com", connection_resource_id: nil}
}

# 2. Execute Write (Partition 1, User a@, ReplyTo b@, Device 1, type 1, context 1, payload, mid)
Queue.QueueLogImpl.write(1, user, "b@domain.com", "1", 1, 1, msg_struct, msg_struct.peer_uid)

# 3. Wait a moment for the write to settle in the ETS buffer
:timer.sleep(100)

# 4. Attempt Fetch
IO.puts "--- ATTEMPTING FETCH ---"
case Queue.QueueLogImpl.fetch_batch(user, 1, "aaaaa1", 10) do
  {:ok, msgs} -> 
    IO.puts "SUCCESS! Found #{length(msgs)} messages."
    IO.inspect(msgs)
  error -> 
    IO.puts "FAILED!"
    IO.inspect(error)
end