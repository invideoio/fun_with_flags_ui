defmodule FunWithFlags.UI.TestWorkspace do
  @moduledoc false
  # A group implementation that lists its groups (FunWithFlags.UI.GroupCatalog),
  # shaped like a real host app's: exact names, a `when ... in` guard,
  # patterns, and a private helper. In test/support for protocol consolidation.
  defstruct [:bucket, :country_group, tags: []]

  def country_groups, do: [:platinum, :gold]
end

defimpl FunWithFlags.Group, for: FunWithFlags.UI.TestWorkspace do
  use FunWithFlags.UI.GroupCatalog,
    hints: %{
      "country_group:" => {FunWithFlags.UI.TestWorkspace, :country_groups, []},
      "created_at:gt:" => "unix timestamp"
    }

  def in?(%{bucket: bucket}, "a0"), do: bucket == :a0
  def in?(%{bucket: bucket}, group) when group in ~w(a b), do: String.starts_with?(to_string(bucket), group)
  def in?(_, "email" <> ":eq:" <> "invideo"), do: false
  def in?(%{country_group: cg}, "country_group:" <> group), do: to_string(cg) == group
  def in?(_, "created_at:gt:" <> _timestamp), do: false
  def in?(%{tags: tags}, "tags:has:" <> tag), do: tag in tags
  def in?(%{bucket: bucket}, group), do: matches?(bucket, group)

  defp matches?(bucket, "signup_a0"), do: bucket == :a0
  defp matches?(_, _), do: false
end
