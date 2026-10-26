defmodule FunWithFlags.UI.FlagMarkdownTest do
  use ExUnit.Case, async: true

  alias FunWithFlags.{Flag, Gate}
  alias FunWithFlags.UI.FlagMarkdown

  test "exports the full configuration, including gates that do not affect the summary" do
    flag = %Flag{name: :checkout, gates: [
      %Gate{type: :boolean, enabled: true},
      %Gate{type: :actor, for: "email:z@example.com", enabled: false},
      %Gate{type: :actor, for: "email:a@example.com", enabled: true},
      %Gate{type: :group, for: :beta, enabled: true},
      %Gate{type: :group, for: :blocked, enabled: false},
      %Gate{type: :percentage_of_actors, for: 0.125, enabled: true}
    ]}

    markdown = FlagMarkdown.render(flag)
    assert markdown =~ "# Feature flag: `\"checkout\"`"
    assert markdown =~ "## Default (boolean gate)\n\nOn"
    assert markdown =~ "## Actors (2)\n\n- `\"email:a@example.com\"`: On\n- `\"email:z@example.com\"`: Off"
    assert markdown =~ "## Groups (2)\n\n- `\"beta\"`: On\n- `\"blocked\"`: Off"
    assert markdown =~ "12.5% of actors (ratio: 0.125)."
    assert markdown =~ "rollout has no effect while the default is On"
    assert markdown =~ "An explicit actor gate decides first"
    assert markdown =~ "Off wins if both On and Off groups match"
    assert markdown == FlagMarkdown.render(%{flag | gates: Enum.reverse(flag.gates)})
  end

  test "distinguishes a missing boolean gate from an explicit Off" do
    empty = FlagMarkdown.render(%Flag{name: :empty, gates: []})
    assert empty =~ "Off (no boolean gate configured)"
    assert empty =~ "## Actors (0)\n\nNone."
    assert empty =~ "## Groups (0)\n\nNone."
    assert empty =~ "## Percentage rollout\n\nNone."

    off = FlagMarkdown.render(%Flag{name: :off, gates: [Gate.new(:boolean, false)]})
    assert off =~ "## Default (boolean gate)\n\nOff\n"
    refute off =~ "no boolean gate configured"
  end

  test "time rollouts retain the exact ratio even below the display precision" do
    flag = %Flag{name: :tiny, gates: [%Gate{type: :percentage_of_time, for: 0.0012345, enabled: true}]}
    assert FlagMarkdown.render(flag) =~ "% of time (ratio: 0.0012345)."
  end

  test "includes every actor, beyond the panel's collapsed rows" do
    gates = for i <- 1..225, do: %Gate{type: :actor, for: "user:#{i}", enabled: rem(i, 2) == 0}
    markdown = FlagMarkdown.render(%Flag{name: :many, gates: gates})
    assert markdown =~ "## Actors (225)"
    for gate <- gates do
      state = if gate.enabled, do: "On", else: "Off"
      assert markdown =~ "- `\"#{gate.for}\"`: #{state}\n"
    end
  end

  test "identifiers with Markdown delimiters, HTML and newlines remain literal" do
    flag = %Flag{name: :"a`b", gates: [
      %Gate{type: :actor, for: "line\n```<script>\"&|", enabled: false}
    ]}
    markdown = FlagMarkdown.render(flag)
    assert markdown =~ "# Feature flag: ``\"a`b\"``"
    assert markdown =~ "- ````\"line\\n```<script>\\\"&|\"````: Off"
  end
end
