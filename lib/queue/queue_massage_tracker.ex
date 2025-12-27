defmodule Queue.MessageTracker do
  @moduledoc """
  High-throughput, in-memory message tracker for 50M+ records.
  Features:
    - Two-generation ETS partitioning
    - Optional per-message TTL
    - Persistent_term for zero-lock active generation
    - Smooth, throttled rotation
    - Optional sweep for expired messages
  """
  require Logger

  @partitions 256
  @default_ttl 43_200 # 12 hours in seconds
  @active_gen_key :message_tracker_active_gen

  @gen_0_names Enum.map(0..(@partitions - 1), &String.to_atom("msg_tracker_g0_#{&1}")) |> List.to_tuple()
  @gen_1_names Enum.map(0..(@partitions - 1), &String.to_atom("msg_tracker_g1_#{&1}")) |> List.to_tuple()

  # ---------------- Public helpers ----------------
  def partitions, do: @partitions
  def gen_0_names, do: @gen_0_names
  def gen_1_names, do: @gen_1_names

  # -------------------------------------------------------------------
  # Initialization
  # -------------------------------------------------------------------
  def init do
    :persistent_term.put(@active_gen_key, 0)

    init_gen(@gen_0_names, :gen0)
    init_gen(@gen_1_names, :gen1)

    Logger.info("MessageTracker initialized with #{@partitions} partitions per generation.")
    :ok
  end

  defp init_gen(names, gen_label) do
    Enum.each(Tuple.to_list(names), fn table ->
      if :ets.info(table) == :undefined do
        :ets.new(table, [:set, :public, :named_table, read_concurrency: true, write_concurrency: :auto])
        Logger.debug("ETS Partition #{table} (#{gen_label}) created.")
      end
    end)
  end

  # -------------------------------------------------------------------
  # Check & Insert (with optional TTL)
  # -------------------------------------------------------------------
  def check_and_insert(user, message_id, ttl_seconds \\ @default_ttl) do
    key = {user, message_id}
    idx = :erlang.phash2(key, @partitions)
    active_idx = :persistent_term.get(@active_gen_key)

    {current_gen, old_gen} =
      if active_idx == 0, do: {@gen_0_names, @gen_1_names}, else: {@gen_1_names, @gen_0_names}

    current_table = elem(current_gen, idx)
    old_table = elem(old_gen, idx)
    now = :erlang.monotonic_time(:second)

    # 1. Check old generation
    case :ets.lookup(old_table, key) do
      [{^key, ts, ttl}] when ts + ttl > now -> {:error, :already_exists}
      _ ->
        record = {key, now, ttl_seconds}

        # 2. Optimistic insert into current generation
        case :ets.insert_new(current_table, record) do
          true -> {:ok, :inserted}
          false ->
            [{^key, ts, ttl}] = :ets.lookup(current_table, key)

            if ts + ttl < now do
              :ets.insert(current_table, record)
              {:ok, :inserted}
            else
              {:error, :already_exists}
            end
        end
    end
  end

  # -------------------------------------------------------------------
  # Optional sweep of expired messages (current generation only)
  # -------------------------------------------------------------------
  def sweep do
    active_idx = :persistent_term.get(@active_gen_key)
    current_gen = if active_idx == 0, do: @gen_0_names, else: @gen_1_names
    now = :erlang.monotonic_time(:second)

    Enum.each(0..(@partitions - 1), fn idx ->
      table = elem(current_gen, idx)

      :ets.select_delete(
        table,
        [
          {{:"$1", :"$2", :"$3"}, [{:<, {:+, :"$2", :"$3"}, now}], [true]}
        ]
      )
    end)

    Logger.info("MessageTracker sweep complete for current generation.")
  end

  # -------------------------------------------------------------------
  # Smooth generation rotation
  # -------------------------------------------------------------------
  def rotate do
    active_idx = :persistent_term.get(@active_gen_key)
    new_active_idx = if active_idx == 0, do: 1, else: 0
    to_clear = if new_active_idx == 0, do: @gen_0_names, else: @gen_1_names

    # Switch active generation immediately
    :persistent_term.put(@active_gen_key, new_active_idx)

    # Clear old generation in background with throttling
    Task.start(fn ->
      Enum.each(Tuple.to_list(to_clear), fn table ->
        :ets.delete_all_objects(table)
        Process.sleep(20) # prevents BEAM spikes
      end)

      Logger.info("MessageTracker rotation complete. New active generation: #{new_active_idx}")
    end)
  end
end
