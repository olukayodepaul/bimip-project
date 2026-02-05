defmodule Queue.ShardServer do
  use GenServer

  def start_link(shard_id), do: GenServer.start_link(__MODULE__, shard_id, name: name(shard_id))

  def get_next_offsets(shard_id, user_id) do
    GenServer.call(name(shard_id), {:get_next_offsets, user_id})
  end

  defp name(shard_id), do: :"shard_sequencer_#{shard_id}"

  # --- Callbacks ---

  def init(shard_id) do
    u_offsets = :"bimip_user_offsets_#{shard_id}"

    # 1. Force load the manifest directly from disk to be 100% sure
    manifest = Queue.QueueLogImpl.load_manifest(shard_id)
    global_start = manifest.msg_count

    # 2. Seed the ETS table so everyone sees the same truth
    :ets.insert(u_offsets, {:manifest_snapshot, manifest})
    :ets.insert(u_offsets, {{:shard_offset, shard_id}, global_start})
    :ets.insert(u_offsets, {{:last_shard_offset, shard_id}, global_start})

    # 3. CRITICAL: Store that global_start in the GenServer State
    {:ok, %{shard_id: shard_id, shard_offset: global_start, ets_tab: u_offsets}}
  end

  def handle_call({:get_next_offsets, user_id}, _from, state) do
    # 1. Increment Shard Offset (The global timeline)
    new_shard_off = state.shard_offset + 1

    # 2. Increment User Offset
    # This key {user_id, 1} MUST match what system_recovery inserted.
    # If system_recovery inserted 11, this returns 12.
    user_off = :ets.update_counter(state.ets_tab, {user_id, 1}, {2, 1}, {{user_id, 1}, 0})

    # 3. Update Global State
    :ets.insert(state.ets_tab, {{:shard_offset, state.shard_id}, new_shard_off})

    {:reply, {user_off, new_shard_off}, %{state | shard_offset: new_shard_off}}
  end

end
