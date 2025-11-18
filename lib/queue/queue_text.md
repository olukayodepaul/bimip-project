# In iex
iex> alias Queue.Injection

# Write a message
iex> {:ok, offset1} = Injection.write("user1", 1, "from1", "to1", %{text: "Hello"})
{:ok, 1}

iex> {:ok, offset2} = QueueController.write("user1", 1, "from2", "to2", %{text: "World"})
{:ok, 2}

# Fetch messages for a device
iex> Injection.fetch("user1", "device1", 1, 10)
{:ok,
 %{
   current_segment: 1,
   device_offset: 0,
   first_segment: 1,
   messages: [
     %{offset: 1, payload: %{...}, from: "from1", to: "to1", ...},
     %{offset: 2, payload: %{...}, from: "from2", to: "to2", ...}
   ],
   target_offset: 1
 }}

# Acknowledge a message
iex> Injection.ack_message("user1", "device1", 1, 1)
{:ok, 1}

# Check message status
iex> Injection.message_status("user1", "device1", 1, 1)
%{sent: true, delivered: false, read: false}

iex> Injection.get_ack_status("user1", "device1", 1, 2)
%{sent: false, delivered: false, read: false}


Injection.ack_status("user1", "device1", 1, 1, :delivered)