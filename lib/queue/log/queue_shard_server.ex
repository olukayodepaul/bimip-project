defmodule Queue.ShardServer do
  use GenServer

  def start_link(shard_id), do: GenServer.start_link(__MODULE__, shard_id, name: name(shard_id))

  def get_next_offsets(shard_id, user_id) do
    GenServer.call(name(shard_id), {:get_next_offsets, user_id})
  end

  defp name(shard_id), do: :"shard_sequencer_#{shard_id}"

  # --- Callbacks ---

  def init(shard_id) do
    # On startup, recover the last shard_offset from the ETS table managed by QueueLogImpl
    u_offsets = :"bimip_user_offsets_#{shard_id}"

    initial_shard_off = case :ets.lookup(u_offsets, {:shard_offset, shard_id}) do
      [{_, val}] -> val
      [] -> 0
    end

    {:ok, %{shard_id: shard_id, shard_offset: initial_shard_off, ets_tab: u_offsets}}
  end

  def handle_call({:get_next_offsets, user_id}, _from, state) do
    # 1. Increment Shard Offset
    new_shard_off = state.shard_offset + 1

    # 2. Increment User Offset (Atomically within this process)
    # We use update_counter here just to keep the ETS table in sync for fetches
    user_off = :ets.update_counter(state.ets_tab, {user_id, 1}, {2, 1}, {{user_id, 1}, 0})

    # 3. Keep ETS Shard Offset in sync for recovery/manifests
    :ets.insert(state.ets_tab, {{:shard_offset, state.shard_id}, new_shard_off})
    {:reply, {user_off, new_shard_off}, %{state | shard_offset: new_shard_off}}
  end
end
