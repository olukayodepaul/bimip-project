defmodule Queue.BimipCompactor do
  @moduledoc """
  Background process for historical segment merging and TTL retention.
  """
  use GenServer
  require Logger

  @base_dir "data/bimip"
  @merge_threshold 5
  @check_interval 60_000
  @retention_days 7

  def start_link(_), do: GenServer.start_link(__MODULE__, %{}, name: __MODULE__)

  @impl true
  def init(state) do
    schedule_check()
    {:ok, state}
  end

  @impl true
  def handle_info(:check_compaction, state) do
    cutoff = System.system_time(:second) - (@retention_days * 86400)
    for shard <- 0..63, do: maybe_compact_shard(shard, cutoff)
    schedule_check()
    {:noreply, state}
  end

  defp maybe_compact_shard(shard, cutoff) do
    segments = find_historical_segments(shard)
    if length(segments) >= @merge_threshold, do: perform_merge(shard, segments, cutoff)
  end

  defp perform_merge(shard, segments, cutoff) do
    new_base = System.unique_integer([:monotonic, :positive])
    temp_log = Path.join(@base_dir, "shard_#{shard}_#{new_base}.comp.log")
    temp_idx = Path.join(@base_dir, "shard_#{shard}_#{new_base}.comp.idx")

    {:ok, out_log} = :file.open(temp_log, [:write, :raw, :binary])
    {:ok, out_idx} = :file.open(temp_idx, [:write, :raw, :binary])

    mappings = Enum.flat_map(segments, fn base ->
      copy_segment_with_retention(shard, base, out_log, out_idx, new_base, cutoff)
    end)

    :file.close(out_log)
    :file.close(out_idx)

    final_log = Path.join(@base_dir, "shard_#{shard}_#{new_base}.log")
    final_idx = Path.join(@base_dir, "shard_#{shard}_#{new_base}.idx")
    File.rename(temp_log, final_log)
    File.rename(temp_idx, final_idx)

    worker = :"bimip_shard_#{shard}"
    GenServer.call(worker, {:compact_swap, segments, new_base, %{log: final_log, idx: final_idx}, mappings})
  end

  defp copy_segment_with_retention(shard, base, out_log, out_idx, new_base, cutoff) do
    idx_path = Path.join(@base_dir, "shard_#{shard}_#{base}.idx")
    log_path = Path.join(@base_dir, "shard_#{shard}_#{base}.log")

    case File.read(idx_path) do
      {:ok, bin} -> process_idx_entries(log_path, out_log, out_idx, new_base, cutoff, bin, [])
      _ -> []
    end
  end

  defp process_idx_entries(src, out_log, out_idx, new_base, cutoff, <<ul::16, u_bin::binary-size(ul), p::32, off::64, pos::64, rest::binary>>, acc) do
    {:ok, fd} = :file.open(src, [:read, :raw, :binary])
    {:ok, <<0xEE, size::32, crc::32, ulen::16, ts::64>>} = :file.pread(fd, pos, 19)

    acc = if ts > cutoff do
      {:ok, body} = :file.pread(fd, pos + 19, ulen + 12 + size)
      {:ok, n_pos} = :file.position(out_log, :cur)
      :ok = :file.write(out_log, [<<0xEE, size::32, crc::32, ulen::16, ts::64>>, body])
      :ok = :file.write(out_idx, <<ulen::16, u_bin::binary, p::32, off::64, n_pos::64>>)
      user = try do String.to_existing_atom(u_bin) rescue _ -> u_bin end
      [{{user, p, off}, {new_base, n_pos}} | acc]
    else
      acc
    end
    :file.close(fd)
    process_idx_entries(src, out_log, out_idx, new_base, cutoff, rest, acc)
  end
  defp process_idx_entries(_, _, _, _, _, _, acc), do: acc

  defp find_historical_segments(shard) do
    active_base = case File.read(Path.join(@base_dir, "shard_#{shard}.manifest")) do
      {:ok, bin} -> :erlang.binary_to_term(bin).base
      _ -> nil
    end

    Path.join(@base_dir, "shard_#{shard}_*.idx")
    |> Path.wildcard()
    |> Enum.map(fn p ->
      [_, _, b] = p |> Path.basename(".idx") |> String.split("_")
      String.to_integer(b)
    end)
    |> Enum.reject(&(&1 == active_base))
    |> Enum.sort()
  end

  defp schedule_check, do: Process.send_after(self(), :check_compaction, @check_interval)
end
