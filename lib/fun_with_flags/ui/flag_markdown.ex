defmodule FunWithFlags.UI.FlagMarkdown do
  @moduledoc false

  alias FunWithFlags.Flag
  alias FunWithFlags.UI.{Summary, Utils}

  # Use the full flag, never the visible/filterable gate rows in the browser.
  def render(%Flag{} = flag) do
    """
    # Feature flag: #{identifier(flag.name)}

    #{Summary.sentence(flag)}

    ## Default (boolean gate)

    #{default(flag)}

    #{gates("Actors", Utils.actor_gates(flag))}

    #{gates("Groups", Utils.group_gates(flag))}

    ## Percentage rollout

    #{percentage(flag)}

    ## Evaluation rules

    For checks with an actor:

    1. An explicit actor gate decides first (On or Off).
    2. Otherwise, matching group gates decide; Off wins if both On and Off groups match.
    3. Otherwise, an On boolean gate enables the flag.
    4. Otherwise, the percentage rollout applies, if configured; without one the flag is Off.

    Without an actor, only the boolean gate and percentage-of-time rollout apply. Percentage-of-actors rollouts select a stable subset; percentage-of-time rollouts are random on each check.

    Group membership is determined by the host application's code. Actor and group identifiers above are quoted strings with escaped special characters.
    """
  end

  defp default(flag) do
    case Utils.boolean_gate_open?(flag) do
      {:ok, enabled} -> state(enabled)
      :missing -> "Off (no boolean gate configured)"
    end
  end

  defp gates(title, gates) do
    rows = Enum.map_join(gates, "\n", fn gate -> "- #{identifier(gate.for)}: #{state(gate.enabled)}" end)
    "## #{title} (#{length(gates)})\n\n" <> if(gates == [], do: "None.", else: rows)
  end

  defp percentage(flag) do
    case Utils.percentage_gate(flag) do
      nil -> "None."
      gate ->
        kind = if gate.type == :percentage_of_actors, do: "actors", else: "time"
        "#{Utils.as_percentage(gate.for)}% of #{kind} (ratio: #{gate.for})."
    end
  end

  defp state(true), do: "On"
  defp state(false), do: "Off"

  # Quoting preserves whitespace/control characters; a longer Markdown code
  # delimiter keeps literal backticks in names from breaking the document.
  defp identifier(value) do
    quoted = inspect(to_string(value), printable_limit: :infinity)
    longest =
      ~r/`+/
      |> Regex.scan(quoted)
      |> List.flatten()
      |> Enum.map(&String.length/1)
      |> Enum.max(fn -> 0 end)
    fence = String.duplicate("`", longest + 1)
    fence <> quoted <> fence
  end
end
