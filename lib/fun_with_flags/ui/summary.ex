defmodule FunWithFlags.UI.Summary do
  @moduledoc false

  # One plain sentence saying who a flag is on for, built from its gates.
  #
  # It follows FunWithFlags' evaluation order (FunWithFlags.Flag.enabled?/2):
  #
  #   1. an actor gate for the actor decides;
  #   2. else group gates: a disabled group beats an enabled one;
  #   3. else the boolean gate, if it is on;
  #   4. else the percentage gate (% of actors, or % of time).
  #
  # So "everyone else" is decided by the boolean and percentage gates, group
  # gates override that, and actor gates override groups. Clauses are only
  # added when they change somebody's result; gates that can't (an enabled
  # group on a flag that is on for everyone, a disabled actor on a flag that
  # is off for everyone and has no enabled groups or percentage) are left
  # out. Where an actor gate and a group gate can disagree for the same
  # actor, a second sentence says which wins.
  #
  # Tested against FunWithFlags.Flag.enabled?/2 in test/fun_with_flags/ui/summary_test.exs.

  alias FunWithFlags.{Flag, Gate}
  alias FunWithFlags.UI.Utils

  def sentence(%Flag{gates: gates}) do
    facts = facts(gates)
    main = main_clause(facts)
    notes = notes(facts)
    Enum.join([main | notes], " ")
  end

  # The signed-in viewer's own actor gates on this flag, described as gates
  # only: "Your actor gate email:ana@example.com is on." The dashboard can't
  # know which actor ID the host app checks (it may be user:123, which no
  # email gate ever matches), so this never claims the flag is on or off
  # for the viewer.
  #
  # A gate is the viewer's when its target equals the viewer (the audit
  # user-id header) or ends with ":" <> viewer, case-sensitively, as the
  # core compares actor IDs (Actor.id(actor) == gate.for). A gate that
  # differs only in letter case gets no line. ("Mine" stays case-insensitive:
  # it is a filter, not a statement.)
  #
  # -> nil | "Your actor gate … is on." | "Your actor gates …, … are off."
  #    | "Your actor gate … is on; … is off."
  #
  def for_viewer(_flag, nil), do: nil
  def for_viewer(_flag, ""), do: nil

  def for_viewer(%Flag{gates: gates}, viewer) when is_binary(viewer) do
    gates
    |> Enum.filter(&(Gate.actor?(&1) and viewer_actor?(to_string(&1.for), viewer)))
    |> Enum.sort_by(&to_string(&1.for))
    |> describe_viewer_gates()
  end

  defp viewer_actor?(target, viewer) do
    suffix = ":" <> viewer
    target == viewer or (byte_size(target) > byte_size(suffix) and String.ends_with?(target, suffix))
  end

  defp describe_viewer_gates([]), do: nil

  defp describe_viewer_gates(gates) do
    case Enum.split_with(gates, & &1.enabled) do
      {on, []} -> "Your actor #{gate_list(on)} #{verb_be(on)} on."
      {[], off} -> "Your actor #{gate_list(off)} #{verb_be(off)} off."
      {on, off} -> "Your actor gates #{targets(on)} #{verb_be(on)} on; #{targets(off)} #{verb_be(off)} off."
    end
  end

  defp gate_list([gate]), do: "gate #{gate.for}"
  defp gate_list(gates), do: "gates " <> targets(gates)

  defp targets(gates), do: Enum.map_join(gates, ", ", &to_string(&1.for))

  defp verb_be([_]), do: "is"
  defp verb_be(_), do: "are"

  defp facts(gates) do
    boolean = Enum.find(gates, &Gate.boolean?/1)
    percentage = Enum.find(gates, &(Gate.percentage_of_time?(&1) or Gate.percentage_of_actors?(&1)))

    %{
      on_by_default: match?(%Gate{enabled: true}, boolean),
      percentage: percentage,
      on_actors: Enum.count(gates, &(Gate.actor?(&1) and &1.enabled)),
      off_actors: Enum.count(gates, &(Gate.actor?(&1) and not &1.enabled)),
      on_groups: Enum.count(gates, &(Gate.group?(&1) and &1.enabled)),
      off_groups: Enum.count(gates, &(Gate.group?(&1) and not &1.enabled))
    }
  end

  # The default for an actor no gate names is on: "On for everyone", and only
  # explicit offs matter.
  defp main_clause(%{on_by_default: true} = f) do
    case join([count(f.off_actors, "actor"), count(f.off_groups, "group")]) do
      "" -> "On for everyone."
      offs -> "On for everyone except #{offs}."
    end
  end

  # Partly on by percentage: explicit ons add to it, explicit offs carve out.
  defp main_clause(%{percentage: %Gate{} = pct} = f) do
    ons = [count(f.on_actors, "actor"), count(f.on_groups, "group")]
    offs = join([count(f.off_actors, "actor"), count(f.off_groups, "group")])

    head =
      case {pct.type, join(ons)} do
        {:percentage_of_actors, ""} -> "On for #{percent(pct)} of actors"
        {:percentage_of_actors, named} -> "On for #{named} and #{percent(pct)} of actors"
        {:percentage_of_time, ""} -> "On #{percent(pct)} of the time"
        {:percentage_of_time, named} -> "On for #{named}, and #{percent(pct)} of the time for everyone else"
      end

    if offs == "", do: head <> ".", else: head <> "; off for #{offs}."
  end

  # Off by default: only explicit ons matter, and offs only where they can
  # override one (a disabled actor or group inside an enabled group).
  defp main_clause(f) do
    case join([count(f.on_actors, "actor"), count(f.on_groups, "group")]) do
      "" ->
        "Off for everyone."

      ons ->
        offs =
          if f.on_groups > 0,
            do: join([count(f.off_actors, "actor"), count(f.off_groups, "group")]),
            else: ""

        if offs == "",
          do: "On for #{ons}; off for everyone else.",
          else: "On for #{ons}, except #{offs}; off for everyone else."
    end
  end

  # Where per-actor and per-group gates can disagree for one actor, and only
  # when both disagreeing clauses are in the sentence.
  defp notes(f) do
    [
      actor_vs_group?(f) && "An actor's own gate wins over its groups.",
      on_groups_named?(f) and off_groups_named?(f) && "In both an on and an off group, off wins.",
      ineffective_rollout?(f) && "The #{percent(f.percentage)} rollout has no effect while the default is On."
    ]
    |> Enum.filter(&is_binary/1)
  end

  # Something for an explicit "off" to override: a default of On, a
  # percentage, or an enabled group.
  defp offs_matter?(f), do: f.on_by_default or f.percentage != nil or f.on_groups > 0

  # Disabled groups / actors are named unless there is nothing to override.
  defp off_groups_named?(f), do: f.off_groups > 0 and offs_matter?(f)
  defp off_actors_named?(f), do: f.off_actors > 0 and offs_matter?(f)

  # Enabled groups are named unless the flag is on for everyone anyway.
  defp on_groups_named?(f), do: f.on_groups > 0 and not f.on_by_default

  defp actor_vs_group?(f) do
    (f.on_actors > 0 and off_groups_named?(f)) or (off_actors_named?(f) and on_groups_named?(f))
  end

  defp ineffective_rollout?(f), do: f.on_by_default and f.percentage != nil

  defp count(0, _noun), do: nil
  defp count(1, noun), do: "1 #{noun}"
  defp count(n, noun), do: "#{n} #{noun}s"

  defp join(parts) do
    case Enum.reject(parts, &is_nil/1) do
      [] -> ""
      [one] -> one
      [a, b] -> "#{a} and #{b}"
    end
  end

  defp percent(%Gate{for: ratio}) do
    percentage = Utils.as_percentage(ratio)
    if round(percentage) == percentage, do: "#{round(percentage)}%", else: "#{percentage}%"
  end
end
