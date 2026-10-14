defmodule Preview.Workspace do
  @moduledoc false
  # A made-up group implementation, shaped like a host app's, so the preview's
  # add-group picker has groups in code (see FunWithFlags.UI.GroupCatalog).
  defstruct [:bucket, :email, :country_group, :created_at, tags: [], flags: %{}]

  def country_groups, do: ~w(platinum gold silver bronze row)
end

defimpl FunWithFlags.Group, for: Preview.Workspace do
  use FunWithFlags.UI.GroupCatalog,
    hints: %{
      "country_group:" => {Preview.Workspace, :country_groups, []},
      "created_at:gt:" => "unix timestamp (seconds)",
      "tags:has:" => "tag",
      "all:" => "groups joined by &, e.g. a0&beta"
    }

  def in?(%{bucket: bucket}, group) when group in ~w(a0 a1 a2 a3 b0 b1 b2 b3 c0 c1 c2 c3 d0 d1 d2 d3),
    do: Atom.to_string(bucket) == group

  def in?(%{bucket: bucket}, group) when group in ~w(a b c d),
    do: bucket |> Atom.to_string() |> String.starts_with?(group)

  def in?(%{flags: %{alpha: true}}, "alpha"), do: true
  def in?(%{flags: flags}, "beta"), do: Map.get(flags, :alpha, false) or Map.get(flags, :beta, false)
  def in?(%{email: email}, "email" <> ":eq:" <> "invideo"), do: String.ends_with?(email || "", "@invideo.io")
  def in?(%{country_group: cg}, "country_group:" <> group), do: to_string(cg) == group
  def in?(%{created_at: at}, "created_at:gt:" <> ts), do: at > String.to_integer(ts)
  def in?(%{tags: tags}, "tags:has:" <> tag), do: tag in tags
  def in?(ws, "all:" <> groups), do: groups |> String.split("&") |> Enum.all?(&in?(ws, &1))
  def in?(_, _), do: false
end
