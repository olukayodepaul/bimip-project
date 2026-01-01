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

    # Open the SOURCE log file ONCE here
    case {File.read(idx_path), :file.open(log_path, [:read, :raw, :binary])} do
      {{:ok, bin}, {:ok, src_fd}} ->
        acc = process_idx_entries(src_fd, out_log, out_idx, new_base, cutoff, bin, [])
        :file.close(src_fd)
        acc
      _ -> []
    end
  end

  defp process_idx_entries(src_fd, out_log, out_idx, new_base, cutoff, <<ul::16, u_bin::binary-size(ul), p::32, off::64, pos::64, rest::binary>>, acc) do
    # NO MORE :file.open here!
    new_acc =
      case :file.pread(src_fd, pos, 19) do
        {:ok, <<0xEE, size::32, crc::32, ulen::16, ts::64>>} ->
          if ts > cutoff do
            # Record is within TTL, copy it
            {:ok, body} = :file.pread(src_fd, pos + 19, ulen + 12 + size)
            {:ok, n_pos} = :file.position(out_log, :cur)

            :ok = :file.write(out_log, [<<0xEE, size::32, crc::32, ulen::16, ts::64>>, body])
            :ok = :file.write(out_idx, <<ulen::16, u_bin::binary, p::32, off::64, n_pos::64>>)

            # Add the new mapping to the accumulator
            [{{u_bin, p, off}, {new_base, n_pos}} | acc]
          else
            # Record expired, skip it
            acc
          end

        _ ->
          # Read error or corrupt entry, skip it
          acc
      end

    # Continue processing the rest of the binary with the updated accumulator
    process_idx_entries(src_fd, out_log, out_idx, new_base, cutoff, rest, new_acc)
  end

  # Base case: when binary is empty, return the accumulated mappings
  defp process_idx_entries(_src_fd, _out_log, _out_idx, _new_base, _cutoff, <<>>, acc), do: acc
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
