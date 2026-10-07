defmodule FunWithFlags.UI.SummaryTest do
  use ExUnit.Case, async: true

  # The panel's "who is this on for" sentence, checked against the library's
  # own evaluation (FunWithFlags.Flag.enabled?/2): a sentence that is wrong is
  # worse than none.

  alias FunWithFlags.{Flag, Gate}
  alias FunWithFlags.UI.{Summary, TestUser}

  defp flag(gates), do: %Flag{name: :summary_test_flag, gates: gates}
  defp bool(on), do: %Gate{type: :boolean, for: nil, enabled: on}
  defp actor(id, on), do: %Gate{type: :actor, for: id, enabled: on}
  defp group(name, on), do: %Gate{type: :group, for: name, enabled: on}
  defp pct_actors(r), do: %Gate{type: :percentage_of_actors, for: r, enabled: true}
  defp pct_time(r), do: %Gate{type: :percentage_of_time, for: r, enabled: true}

  defp on?(flag, id, groups \\ []), do: Flag.enabled?(flag, for: %TestUser{id: id, groups: groups})

  # 200 actors nobody named, in no groups
  defp strangers, do: for(i <- 1..200, do: "stranger:#{i}")

  describe "the truth table" do
    test "no gates" do
      f = flag([])
      assert Summary.sentence(f) == "Off for everyone."
      refute Enum.any?(strangers(), &on?(f, &1))
    end

    test "default on" do
      f = flag([bool(true)])
      assert Summary.sentence(f) == "On for everyone."
      assert Enum.all?(strangers(), &on?(f, &1))
    end

    test "default off, or not set" do
      for f <- [flag([bool(false)]), flag([actor("user:1", false)])] do
        assert Summary.sentence(f) == "Off for everyone."
        refute Enum.any?(strangers(), &on?(f, &1))
        refute on?(f, "user:1")
      end
    end

    test "default on, with enabled actors and groups: they change nothing" do
      f = flag([bool(true), actor("user:1", true), group("beta", true)])
      assert Summary.sentence(f) == "On for everyone."
      assert on?(f, "user:1") and on?(f, "x", ["beta"]) and on?(f, "stranger")
    end

    test "default on, except some actors and a group" do
      f = flag([bool(true), actor("user:1", false), actor("user:2", false), group("churned", false)])
      assert Summary.sentence(f) == "On for everyone except 2 actors and 1 group."
      refute on?(f, "user:1")
      refute on?(f, "user:2")
      refute on?(f, "x", ["churned"])
      assert Enum.all?(strangers(), &on?(f, &1))
    end

    test "default on, a disabled group, and an actor enabled by name inside it" do
      f = flag([bool(true), group("churned", false), actor("user:9", true)])
      assert Summary.sentence(f) == "On for everyone except 1 group. An actor's own gate wins over its groups."
      refute on?(f, "x", ["churned"])
      assert on?(f, "user:9", ["churned"])
    end

    test "default off, on for some actors and groups" do
      f = flag([bool(false), actor("user:1", true), actor("user:2", true), actor("user:3", true), group("beta", true)])
      assert Summary.sentence(f) == "On for 3 actors and 1 group; off for everyone else."
      assert on?(f, "user:1") and on?(f, "user:3") and on?(f, "x", ["beta"])
      refute Enum.any?(strangers(), &on?(f, &1))
    end

    test "default off, on for an enabled group, except an actor and a disabled group" do
      f = flag([bool(false), group("beta", true), group("churned", false), actor("user:1", false)])
      assert Summary.sentence(f) ==
               "On for 1 group, except 1 actor and 1 group; off for everyone else. " <>
                 "An actor's own gate wins over its groups. In both an on and an off group, off wins."
      assert on?(f, "x", ["beta"])
      refute on?(f, "user:1", ["beta"])
      refute on?(f, "x", ["beta", "churned"])
      refute Enum.any?(strangers(), &on?(f, &1))
    end

    test "default off, only actors on: disabled actors and groups are left out (they change nothing)" do
      f = flag([bool(false), actor("user:1", true), actor("user:2", false), group("churned", false)])
      assert Summary.sentence(f) == "On for 1 actor; off for everyone else."
      assert on?(f, "user:1", ["churned"])
      refute on?(f, "user:2")
      refute on?(f, "x", ["churned"])
    end

    test "% of actors" do
      f = flag([bool(false), pct_actors(0.25)])
      assert Summary.sentence(f) == "On for 25% of actors."
      results = Enum.map(strangers(), &on?(f, &1))
      share = Enum.count(results, & &1) / length(results)
      assert share > 0.1 and share < 0.4
    end

    test "% of actors plus named groups and actors, with exceptions" do
      f = flag([pct_actors(0.25), group("beta", true), group("qa", true), actor("user:1", false)])
      assert Summary.sentence(f) ==
               "On for 2 groups and 25% of actors; off for 1 actor. An actor's own gate wins over its groups."
      assert on?(f, "x", ["beta"]) and on?(f, "y", ["qa"])
      refute on?(f, "user:1", ["beta"])
    end

    test "% of the time" do
      f = flag([bool(false), pct_time(0.5)])
      assert Summary.sentence(f) == "On 50% of the time."
      results = for _ <- 1..400, do: on?(f, "stranger:1")
      assert Enum.any?(results) and not Enum.all?(results)
    end

    test "% of the time plus named actors" do
      f = flag([pct_time(0.5), actor("user:1", true)])
      assert Summary.sentence(f) == "On for 1 actor, and 50% of the time for everyone else."
      assert Enum.all?(for _ <- 1..50, do: on?(f, "user:1"))
    end

    test "default on with a percentage: the rollout does nothing, and the sentence says so" do
      f = flag([bool(true), pct_actors(0.1)])
      assert Summary.sentence(f) == "On for everyone. The 10% rollout has no effect while the default is On."
      assert Enum.all?(strangers(), &on?(f, &1))
    end

    test "fractional percentages keep their precision" do
      assert Summary.sentence(flag([pct_actors(0.421337)])) == "On for 42.1337% of actors."
    end
  end

  # Every combination of: default (on/off/unset) × percentage (none/actors/time)
  # × 0–2 enabled/disabled actors × 0–2 enabled/disabled groups, checked
  # against the library for the claim the sentence makes about everyone.
  describe "exhaustive sweep" do
    test "'On for everyone' / 'Off for everyone' / the percentage head always hold" do
      for b <- [true, false, nil], p <- [nil, :actors, :time],
          a_on <- 0..2, a_off <- 0..2, g_on <- 0..2, g_off <- 0..2 do
        gates =
          List.flatten([
            if(b == nil, do: [], else: [bool(b)]),
            case p do
              nil -> []
              :actors -> [pct_actors(0.5)]
              :time -> [pct_time(0.5)]
            end,
            for(i <- 1..a_on//1, do: actor("on:#{i}", true)),
            for(i <- 1..a_off//1, do: actor("off:#{i}", false)),
            for(i <- 1..g_on//1, do: group("gon#{i}", true)),
            for(i <- 1..g_off//1, do: group("goff#{i}", false))
          ])

        f = flag(gates)
        s = Summary.sentence(f)
        label = "#{inspect({b, p, a_on, a_off, g_on, g_off})}: #{s}"

        named_on = for i <- 1..a_on//1, do: "on:#{i}"
        named_off = for i <- 1..a_off//1, do: "off:#{i}"
        on_groups = for i <- 1..g_on//1, do: "gon#{i}"
        off_groups = for i <- 1..g_off//1, do: "goff#{i}"

        cond do
          String.starts_with?(s, "On for everyone.") ->
            # literally everyone: strangers, named actors, any group member
            assert Enum.all?(Enum.take(strangers(), 30), &on?(f, &1)), label
            assert Enum.all?(named_on ++ named_off, &on?(f, &1)), label
            assert Enum.all?(on_groups ++ off_groups, &on?(f, "m", [&1])), label

          String.starts_with?(s, "On for everyone except") ->
            assert Enum.all?(Enum.take(strangers(), 30), &on?(f, &1)), label
            refute Enum.any?(named_off, &on?(f, &1)), label
            refute Enum.any?(off_groups, &on?(f, "m", [&1])), label
            assert Enum.all?(named_on, &on?(f, &1, off_groups)), label

          s == "Off for everyone." ->
            refute Enum.any?(Enum.take(strangers(), 30), &on?(f, &1)), label
            refute Enum.any?(named_on ++ named_off, &on?(f, &1)), label
            refute Enum.any?(on_groups ++ off_groups, &on?(f, "m", [&1])), label

          String.ends_with?(hd(String.split(s, ". ")), "off for everyone else") or
              String.contains?(s, "; off for everyone else.") ->
            refute Enum.any?(Enum.take(strangers(), 30), &on?(f, &1)), label
            assert Enum.all?(named_on, &on?(f, &1)), label
            refute Enum.any?(named_off, &on?(f, &1, on_groups)), label
            assert Enum.all?(on_groups, &on?(f, "m", [&1])), label

          String.contains?(s, "% of actors") ->
            assert p == :actors and b != true, label
            refute Enum.any?(named_off, &on?(f, &1)), label
            assert Enum.all?(named_on, &on?(f, &1)), label
            assert Enum.all?(on_groups, &on?(f, "m", [&1])), label
            refute Enum.any?(off_groups, &on?(f, "m", [&1])), label

          String.contains?(s, "% of the time") ->
            assert p == :time and b != true, label
            refute Enum.any?(named_off, &on?(f, &1)), label
            assert Enum.all?(named_on, &on?(f, &1)), label

          true ->
            flunk("unclassified sentence " <> label)
        end

        # every count the sentence states matches the gates it describes
        for {n, noun} <- Regex.scan(~r/(\d+) (actor|group)s?\b/, s, capture: :all_but_first) |> Enum.map(&List.to_tuple/1) do
          assert String.to_integer(n) in [a_on, a_off, g_on, g_off], label
          _ = noun
        end
      end
    end
  end

  # Round 14 (review R4-2): the viewer's own actor gates, described as
  # gates, matched case-sensitively exactly as the core matches actor IDs.
  # Never a verdict: the app may check an ID no email gate matches.
  describe "for_viewer/2" do
    test "an enabled gate for the viewer: described, and it really decides for that actor ID" do
      f = flag([bool(false), actor("email:ana@example.com", true), group("staff", false), pct_time(0.0)])
      assert Summary.for_viewer(f, "ana@example.com") == "Your actor gate email:ana@example.com is on."
      assert on?(f, "email:ana@example.com", ["staff"])
    end

    test "a disabled gate for the viewer" do
      f = flag([bool(true), actor("workspace:9:ana@example.com", false), group("staff", true)])
      assert Summary.for_viewer(f, "ana@example.com") == "Your actor gate workspace:9:ana@example.com is off."
      refute on?(f, "workspace:9:ana@example.com", ["staff"])
    end

    test "the review's case: a gate differing only in letter case gets no line (the core would not match it)" do
      f = flag([bool(false), actor("email:Ana@Invideo.io", true)])
      assert Summary.for_viewer(f, "ana@invideo.io") == nil
      refute on?(f, "email:ana@invideo.io")
    end

    test "matching: exact or after a colon, case-sensitive; nothing else" do
      f = flag([actor("ana@example.com", true), actor("user:ana@example.com", true), actor("user:ANA@example.com", true),
                actor("xana@example.com", false), actor("ana@example.com.evil", false), actor(":ana@example.com", false)])
      assert Summary.for_viewer(f, "ana@example.com") == "Your actor gates ana@example.com, user:ana@example.com are on."
    end

    test "gates for two of the viewer's IDs that disagree: both described, no verdict" do
      f = flag([actor("email:ana@example.com", true), actor("user:ana@example.com", false)])
      assert Summary.for_viewer(f, "ana@example.com") ==
               "Your actor gates email:ana@example.com is on; user:ana@example.com is off."
    end

    test "no gate for the viewer, or no viewer: nothing (groups and percentages are unknowable here)" do
      f = flag([bool(true), actor("email:bob@example.com", false), group("ana@example.com", true), pct_actors(0.5)])
      assert Summary.for_viewer(f, "ana@example.com") == nil
      assert Summary.for_viewer(f, nil) == nil
      assert Summary.for_viewer(f, "") == nil
    end

    test "the wording never claims a verdict for the viewer" do
      flags = [
        flag([actor("email:ana@example.com", true)]),
        flag([actor("email:ana@example.com", false)]),
        flag([actor("email:ana@example.com", true), actor("user:ana@example.com", false)])
      ]

      for f <- flags do
        text = Summary.for_viewer(f, "ana@example.com")
        assert text =~ ~r/^Your actor gates? /
        refute text =~ ~r/for you/i
      end
    end
  end
end
