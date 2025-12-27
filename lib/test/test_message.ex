defmodule Queue.TestTracker do
  @moduledoc """
  Manual test module for MessageTracker:
    - Insert a message
    - Check active generation
    - Rotate generations
    - Verify message persistence
  """

  alias Queue.MessageTracker

  # Inserts a message and prints status
  def insert_message(user, msg_id) do
    [{:active_gen, active_idx}] = :ets.lookup(:tracker_config, :active_gen)
    IO.puts("Before insert, active generation: #{active_idx} (0 = gen0, 1 = gen1)")

    case MessageTracker.check_and_insert(user, msg_id) do
      {:ok, :inserted} ->
        IO.puts("Message #{msg_id} inserted for #{user}")

      {:error, :already_exists} ->
        IO.puts("Message #{msg_id} already exists for #{user}")
    end

    idx = :erlang.phash2({user, msg_id}, MessageTracker.partitions())
    current_gen =
      if active_idx == 0, do: MessageTracker.gen_0_names(), else: MessageTracker.gen_1_names()

    table = elem(current_gen, idx)
    lookup = :ets.lookup(table, {user, msg_id})
    IO.puts("ETS lookup: #{inspect(lookup)}")
  end

  # Rotate generations and show active generation after rotation
  def rotate_and_check do
    MessageTracker.rotate()
    [{:active_gen, active_idx}] = :ets.lookup(:tracker_config, :active_gen)
    IO.puts("After rotation, active generation: #{active_idx} (0 = gen0, 1 = gen1)")
  end
end
