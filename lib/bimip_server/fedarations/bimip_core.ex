defmodule BimipsSignal.Core do
  alias BimipsSignal.{Connection, Receiver, Sender}

def start_signal do
  # 1. Open the physical pipe
  initial_stream = Connection.connect()

  # 2. PERFORM HANDSHAKE FIRST
  # We must get the 'live' stream back from the sender
  stream = Sender.register(initial_stream)

  # 3. START RECEIVER WITH THE LIVE STREAM
  # Now the Receiver is looking at the stream AFTER the server acknowledged it
  Receiver.start_link(stream)

  # 4. Start the loop
  loop_sending(stream)
end

  defp loop_sending(stream) do
    # Pass the current stream and get the updated one back
    new_stream = Sender.send_to_server(stream, "Heartbeat data...")
    Process.sleep(10_000)
    loop_sending(new_stream)
  end
end
