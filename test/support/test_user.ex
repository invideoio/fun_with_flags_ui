defmodule FunWithFlags.UI.TestUser do
  @moduledoc false
  # An actor that can be in any groups, for checking the panel's summary
  # sentence against FunWithFlags.Flag.enabled?/2. Lives in test/support so
  # its protocol implementations are part of protocol consolidation.
  defstruct [:id, groups: []]
end

defimpl FunWithFlags.Actor, for: FunWithFlags.UI.TestUser do
  def id(%{id: id}), do: id
end

defimpl FunWithFlags.Group, for: FunWithFlags.UI.TestUser do
  def in?(%{groups: groups}, group), do: to_string(group) in groups
end
