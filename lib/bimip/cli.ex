defmodule Bimip.CLI do
  @moduledoc """
  CLI entrypoint for Bimip.
  """

  def main(args) do
    case args do
      ["start"] ->
        IO.puts("Starting Bimip Application...")
        Application.ensure_all_started(:bimips)
        :timer.sleep(:infinity) # Keep the process alive

      _ ->
        IO.puts("Usage: bimips start")
    end
  end
end
