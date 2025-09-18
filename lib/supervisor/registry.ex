defmodule Bimip.Registry do
  #supervisor
  @moduledoc """
  Provides via tuples for device and user GenServers.
  """

  # For child sessions
  def via_registry(device_id), do: {:via, Horde.Registry, {DeviceIdRegistry, device_id}}

  # For Mother process
  def via_monitor_registry(eid), do: {:via, Horde.Registry, {EidRegistry, eid}}
end
