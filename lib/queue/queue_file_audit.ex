defmodule Queue.FileAuditor do
  # Adjust this to match your actual index entry byte size
  @index_entry_size 16

  def audit_all do
    IO.puts "📂 SHARED STORAGE AUDIT (Exact Counts)"
    IO.puts "-------------------------------------------------------"

    Path.wildcard("data/bimip/*.idx")
    |> Enum.sort()
    |> Enum.map(fn idx_path ->
      log_path = String.replace(idx_path, ".idx", ".log")

      # Get exact count from Index file size
      {:ok, %{size: idx_bytes}} = File.stat(idx_path)
      record_count = div(idx_bytes, @index_entry_size)

      # Get physical size from Log file
      {:ok, %{size: log_bytes}} = File.stat(log_path)
      mb_size = Float.round(log_bytes / 1024 / 1024, 2)

      {Path.basename(log_path), record_count, mb_size}
    end)
    |> Enum.each(fn {name, count, mb} ->
      IO.puts "#{name} | Records: #{count} | Size: #{mb} MB"
    end)

    IO.puts "-------------------------------------------------------"
  end
end

Queue.FileAuditor.audit_all()
