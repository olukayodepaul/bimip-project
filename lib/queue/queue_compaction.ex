defmodule Queue.BimipCompactor do
  @moduledoc """
  Background process for historical segment merging and TTL retention.

  Features:
    - Safe segment compaction
    - Atomic manifest updates
    - Sparse index compatible
    - Crash-safe with optional quarantine
  """

  use GenServer
  require Logger

  @base_dir "data/bimip"
  @quarantine_dir "data/bimip/quarantine"
  @merge_threshold 5           # segments before merge
  @check_interval 60_000       # 1 min
  @retention_days 7            # TTL

  # ------------------------------------------------------------------
  # Public API
  # ------------------------------------------------------------------
  def start_link(_) do
    GenServer.start_link(__MODULE__, %{}, name: __MODULE__)
  end

  # ------------------------------------------------------------------
  # GenServer callbacks
  # ------------------------------------------------------------------
  def init(state) do
    File.mkdir_p!(@base_dir)
    File.mkdir_p!(@quarantine_dir)
    schedule_check()
    {:ok, state}
  end

  def handle_info(:check, state) do
    compact_all_segments()
    schedule_check()
    {:noreply, state}
  end

  # ------------------------------------------------------------------
  # Helpers
  # ------------------------------------------------------------------
  defp schedule_check, do: Process.send_after(self(), :check, @check_interval)

  # List all segments in base_dir
  defp all_segments do
    Path.wildcard(Path.join(@base_dir, "segment_*.log"))
    |> Enum.sort()
  end

  # Compact eligible segments
  defp compact_all_segments do
    segments = all_segments()

    # Only compact if enough segments
    if length(segments) >= @merge_threshold do
      {to_merge, rest} = Enum.split(segments, @merge_threshold)

      Logger.info("Compacting segments: #{inspect(to_merge)}")

      case copy_segments_safe(to_merge) do
        {:ok, new_segment} ->
          Logger.info("Compaction successful: #{new_segment}")
          Enum.each(to_merge, &File.rm/1)   # delete old segments

        {:error, failed_segment} ->
          Logger.error("Compaction failed, moved to quarantine: #{failed_segment}")
      end
    end

    # Delete expired segments (TTL)
    delete_old_segments()
  end

  # ------------------------------------------------------------------
  # Crash-Safe Compaction
  # ------------------------------------------------------------------
  defp copy_segments_safe(segments) do
    base = System.unique_integer([:positive])
    new_segment = Path.join(@base_dir, "segment_#{base}.log")

    try do
      # Copy segments sequentially
      Enum.each(segments, fn seg ->
        File.stream!(seg, [], 4096)
        |> Stream.each(fn line ->
          write_with_retry(new_segment, line)
        end)
        |> Stream.run()
      end)

      # Update manifest atomically
      manifest = %{active_base: new_segment, timestamp: System.system_time(:second)}
      persist_manifest_atomic(manifest)

      {:ok, new_segment}
    rescue
      e ->
        Logger.error("Error during segment copy: #{inspect(e)}")
        # Move new_segment to quarantine if partially written
        quarantine_file(new_segment)
        {:error, new_segment}
    end
  end

  # Retry-safe write
  defp write_with_retry(file, data, retries \\ 3)
  defp write_with_retry(_file, _data, 0), do: raise("Failed writing to segment after retries")

  defp write_with_retry(file, data, retries) do
    try do
      File.write!(file, data, [:append])
    rescue
      _ ->
        :timer.sleep(50)
        write_with_retry(file, data, retries - 1)
    end
  end

  # ------------------------------------------------------------------
  # Crash-Safe Manifest
  # ------------------------------------------------------------------
  defp persist_manifest_atomic(manifest) do
    manifest_file = Path.join(@base_dir, "manifest.bin")
    tmp_file = manifest_file <> ".tmp"

    # Write temp file
    File.write!(tmp_file, :erlang.term_to_binary(manifest))

    # Fsync
    {:ok, fd} = :file.open(tmp_file, [:read, :write, :binary])
    :file.sync(fd)
    :file.close(fd)

    # Atomic rename
    File.rename!(tmp_file, manifest_file)
  end

  defp quarantine_file(file) do
    if File.exists?(file) do
      dest = Path.join(@quarantine_dir, Path.basename(file))
      File.rename!(file, dest)
    end
  end

  # ------------------------------------------------------------------
  # TTL Cleanup
  # ------------------------------------------------------------------
  defp delete_old_segments do
    now = System.system_time(:second)

    Path.wildcard(Path.join(@base_dir, "segment_*.log"))
    |> Enum.each(fn file ->
      {:ok, stat} = File.stat(file)
      age_sec = now - stat.mtime |> DateTime.to_unix()
      if age_sec > @retention_days * 86_400, do: File.rm(file)
    end)
  end
end
