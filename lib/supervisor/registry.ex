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


defmodule Bimip.Registry.EidRegistry do
  use Horde.Registry

  def start_link(_args) do
    Horde.Registry.start_link(
      name: __MODULE__,
      keys: :unique,
      members: :auto
    )
  end
end

# lib/bimip/registry/device_id_registry.ex
defmodule Bimip.Registry.DeviceIdRegistry do
  use Horde.Registry

  def start_link(_args) do
    Horde.Registry.start_link(
      name: __MODULE__,
      keys: :unique, 
      members: :auto
    )
  end
end
