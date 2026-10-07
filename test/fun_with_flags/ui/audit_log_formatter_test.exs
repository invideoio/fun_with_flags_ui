defmodule FunWithFlags.UI.AuditLogFormatterTest do
  use ExUnit.Case, async: true

  alias FunWithFlags.UI.AuditLogFormatter

  # Round 13: the core library logs every percentage removal with its
  # internal placeholder gate (percentage_of_time, 0.5). The real gate is in
  # flag_state_before; the placeholder must never be shown.
  describe "clear_gate of a percentage gate" do
    test "a real production row: 10% of actors removed, logged as the 50%-of-time placeholder" do
      data = %{
        "gate" => %{"type" => "percentage_of_time", "target" => "0.5", "enabled" => true},
        "action" => "clear_gate",
        "flag_state_before" => %{
          "gates" => [
            %{"type" => "boolean", "enabled" => true},
            %{"type" => "percentage_of_actors", "target" => "0.1", "enabled" => true}
          ]
        }
      }

      assert AuditLogFormatter.describe(%{data: data}) == "Removed the 10% of actors rollout"
    end

    test "a percentage of time gate, from flag_state_before, with atom keys and a float target" do
      data = %{
        gate: %{type: "percentage_of_time", target: 0.5, enabled: true},
        action: "clear_gate",
        flag_state_before: %{gates: [%{type: "percentage_of_time", target: 0.25, enabled: true}]}
      }

      assert AuditLogFormatter.describe(%{data: data}) == "Removed the 25% of the time rollout"
    end

    test "without flag_state_before, or without a percentage gate in it: neutral, no placeholder" do
      gate = %{"type" => "percentage_of_time", "target" => "0.5", "enabled" => true}

      for data <- [
            %{"gate" => gate, "action" => "clear_gate"},
            %{"gate" => gate, "action" => "clear_gate", "flag_state_before" => nil},
            %{"gate" => gate, "action" => "clear_gate", "flag_state_before" => %{"gates" => [%{"type" => "boolean", "enabled" => true}]}}
          ] do
        text = AuditLogFormatter.describe(%{data: data})
        assert text == "Removed the percentage rollout", inspect(data)
        refute text =~ "50%"
      end
    end
  end

  test "percentages read as the panel shows them, not rounded" do
    data = %{
      "gate" => %{"type" => "percentage_of_time", "target" => "0.5"},
      "action" => "clear_gate",
      "flag_state_before" => %{"gates" => [%{"type" => "percentage_of_actors", "target" => "0.421337"}]}
    }

    assert AuditLogFormatter.describe(%{data: data}) ==
             "Removed the #{FunWithFlags.UI.Templates.percent_text(0.421337)} of actors rollout"

    refute AuditLogFormatter.describe(%{data: data}) =~ "42% "
  end

  test "other clear_gate rows are described as before" do
    assert AuditLogFormatter.describe(%{data: %{"action" => "clear_gate", "gate" => %{"type" => "actor", "target" => "user:<1>"}}}) ==
             "Cleared actor gate for user:&lt;1&gt;"

    assert AuditLogFormatter.describe(%{data: %{"action" => "enable", "gate" => %{"type" => "percentage_of_actors", "target" => "0.1"}}}) ==
             "Enabled percentage of actors gate (10%)"
  end
end
