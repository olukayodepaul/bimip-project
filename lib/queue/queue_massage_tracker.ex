defmodule Queue.MessageTracker do
  @moduledoc """
  Optimized for 50M+ records.
  High-speed ETS partitioning with two-generation aging and optional per-message TTL.
  """
  require Logger

  @partitions 256
  @config_table :tracker_config
  @default_ttl 43_200 # 12 hours in seconds

  @gen_0_names Enum.map(0..(@partitions - 1), &String.to_atom("msg_tracker_g0_#{&1}")) |> List.to_tuple()
  @gen_1_names Enum.map(0..(@partitions - 1), &String.to_atom("msg_tracker_g1_#{&1}")) |> List.to_tuple()

  # -------------------------------------------------------------------
  # Initialization
  # -------------------------------------------------------------------
  def init do
    # Config table
    if :ets.info(@config_table) == :undefined do
      :ets.new(@config_table, [:set, :public, :named_table, read_concurrency: true])
      :ets.insert(@config_table, {:active_gen, 0})
      IO.inspect({@config_table, :created}, label: "ETS CONFIG TABLE")
    else
      IO.inspect({@config_table, :exists}, label: "ETS CONFIG TABLE")
    end

    init_gen(@gen_0_names, :gen0)
    init_gen(@gen_1_names, :gen1)

    :ok
  end

  defp init_gen(names, gen_label) do
    Enum.each(Tuple.to_list(names), fn table ->
      if :ets.info(table) == :undefined do
        :ets.new(
          table,
          [
            :set,
            :public,
            :named_table,
            read_concurrency: true,
            write_concurrency: :auto
          ]
        )

        IO.inspect({table, gen_label, :created}, label: "ETS PARTITION")
      else
        IO.inspect({table, gen_label, :exists}, label: "ETS PARTITION")
      end
    end)
  end

  # -------------------------------------------------------------------
  # Check & Insert with TTL
  # -------------------------------------------------------------------
  def check_and_insert(user, message_id, ttl_seconds \\ @default_ttl) do
    key = {user, message_id}
    idx = :erlang.phash2(key, @partitions)

    [{:active_gen, active_idx}] = :ets.lookup(@config_table, :active_gen)
    {current_gen, old_gen} =
      if active_idx == 0, do: {@gen_0_names, @gen_1_names}, else: {@gen_1_names, @gen_0_names}

    current_table = elem(current_gen, idx)
    old_table = elem(old_gen, idx)

    now = :erlang.monotonic_time(:second)

    case :ets.lookup(old_table, key) do
      [{^key, ts, ttl}] when ts + ttl > now ->
        {:error, :already_exists}

      _ ->
        record = {key, now, ttl_seconds}

        case :ets.insert_new(current_table, record) do
          true ->
            {:ok, :inserted}

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
  # Sweep expired messages
  # -------------------------------------------------------------------
  def sweep do
    [{:active_gen, active_idx}] = :ets.lookup(@config_table, :active_gen)
    current_gen = if active_idx == 0, do: @gen_0_names, else: @gen_1_names
    now = :erlang.monotonic_time(:second)

    Enum.each(0..(@partitions - 1), fn idx ->
      table = elem(current_gen, idx)

      :ets.select_delete(
        table,
        [
          {{:"$1", :"$2", :"$3"},
           [{:<, {:+, :"$2", :"$3"}, now}],
           [true]}
        ]
      )
    end)
  end

  # -------------------------------------------------------------------
  # Generation rotation
  # -------------------------------------------------------------------
  def rotate do
    [{:active_gen, active_idx}] = :ets.lookup(@config_table, :active_gen)
    new_active_idx = if active_idx == 0, do: 1, else: 0
    to_clear = if new_active_idx == 0, do: @gen_0_names, else: @gen_1_names

    Enum.each(Tuple.to_list(to_clear), fn table ->
      :ets.delete_all_objects(table)
      IO.inspect({table, :cleared}, label: "ETS ROTATION")
    end)

    :ets.insert(@config_table, {:active_gen, new_active_idx})
    Logger.info("MessageTracker: Generational rotation complete.")
  end
end
