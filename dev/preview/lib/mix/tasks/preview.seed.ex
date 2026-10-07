defmodule Mix.Tasks.Preview.Seed do
  @shortdoc "Replaces the preview database's flags with a deterministic, real-shaped set"
  @moduledoc """
  Truncates the flags and audit log tables of the preview database and
  seeds ~300 flags with a spread of states, created dates and audit
  entries. Deterministic: the same run produces the same data (relative to
  today's date).

  Made-up people only (`@example.com`): screenshots of this end up on slides.

      mix preview.seed
  """
  use Mix.Task

  alias FunWithFlags.UI.SimpleActor
  alias Preview.Repo

  @flag_count 300
  @recent_count 10
  @no_date_count 12
  @day 24 * 60 * 60

  @people ~w(ana bo chen dara eli fatima gus hana ivan jo kai lena mira noor omar priya quinn ravi sofia tomas)
          |> Enum.map(&"#{&1}@example.com")

  @areas ~w(editor export billing onboarding copilot media_search upload timeline avatar voiceover
            subtitles templates brand_kit workspace auth notifications payments analytics render
            stock_media music scripts storyboard collab sharing api mobile web teams)

  @things ~w(new_ui v2 redesign fast_path beta_banner limits retry_queue kill_switch ab_test
             upsell_modal trial_extension gpu_pool cache prefetch inline_edit autosave dark_mode
             shortcuts bulk_actions webhooks rate_limit sso_enforce audit_export watermark
             smart_crop auto_captions voice_clone hd_export multi_lang)

  @groups ~w(email:eq:invideo a0 a1 a2 a3 b0 b1 b2 b3 c0 c1 c2 c3 d0 d1 d2 d3 alpha beta)

  @impl true
  def run(_args) do
    Mix.Task.run("app.start")
    Logger.configure(level: :info)
    :rand.seed(:exsss, {2026, 10, 7})

    Repo.query!("TRUNCATE fun_with_flags_toggles, fun_with_flags_audit_logs RESTART IDENTITY")

    now = DateTime.utc_now() |> DateTime.truncate(:second)
    names = flag_names()
    created = created_dates(names, now)

    names
    |> Enum.with_index()
    |> Enum.each(fn {name, i} -> seed_flag(name, i) end)

    Enum.each(names, fn name -> backdate(name, Map.fetch!(created, name), now) end)

    flags = Repo.query!("SELECT count(DISTINCT flag_name) FROM fun_with_flags_toggles").rows
    toggles = Repo.query!("SELECT count(*) FROM fun_with_flags_toggles").rows
    audits = Repo.query!("SELECT count(*) FROM fun_with_flags_audit_logs").rows
    Mix.shell().info("seeded #{hd(hd(flags))} flags, #{hd(hd(toggles))} gates, #{hd(hd(audits))} audit entries")
  end

  # --- names ----------------------------------------------------------

  defp flag_names do
    extra = [:"ops.maintenance-mode", :legacy_player_fallback, :enable_new_checkout_flow]

    Stream.repeatedly(fn -> random_name() end)
    |> Stream.uniq()
    |> Enum.take(@flag_count - length(extra))
    |> Kernel.++(extra)
    |> Enum.sort()
  end

  defp random_name do
    area = Enum.random(@areas)
    thing = Enum.random(@things)

    case :rand.uniform(5) do
      1 -> :"enable_#{area}_#{thing}"
      2 -> :"#{area}_#{thing}_rollout"
      _ -> :"#{area}_#{thing}"
    end
  end

  # ~10 flags in the last 14 days, a few with no date (flags that predate
  # the created_at column and have no audit trail), the rest spread over
  # two years.
  #
  defp created_dates(names, now) do
    shuffled = Enum.shuffle(names)
    {recent, rest} = Enum.split(shuffled, @recent_count)
    {undated, old} = Enum.split(rest, @no_date_count)

    Map.new(
      Enum.map(recent, &{&1, DateTime.add(now, -:rand.uniform(13 * @day), :second)}) ++
        Enum.map(undated, &{&1, nil}) ++
        Enum.map(old, &{&1, DateTime.add(now, -(15 * @day + :rand.uniform(715 * @day)), :second)})
    )
  end

  # --- gates ----------------------------------------------------------

  defp seed_flag(name, i) do
    who = Enum.random(@people)

    case state_for(i) do
      :on ->
        FunWithFlags.enable(name, audit(who))
        maybe(0.3, fn -> add_groups(name, 1) end)

      :off ->
        FunWithFlags.disable(name, audit(who))
        maybe(0.15, fn -> add_actors(name, 1 + :rand.uniform(2), false) end)

      :partial_actors ->
        FunWithFlags.disable(name, audit(who))
        add_actors(name, :rand.uniform(8), true)
        maybe(0.3, fn -> add_groups(name, 1) end)

      :partial_groups ->
        FunWithFlags.disable(name, audit(who))
        add_groups(name, 1 + :rand.uniform(3))
        maybe(0.4, fn -> add_actors(name, :rand.uniform(4), true) end)

      :partial_percentage ->
        FunWithFlags.disable(name, audit(who))
        type = Enum.random([:actors, :time])
        ratio = Enum.random([0.01, 0.05, 0.1, 0.25, 0.5, 0.75, 0.421337])
        FunWithFlags.enable(name, [for_percentage_of: {type, ratio}] ++ audit(who))
        maybe(0.3, fn -> add_actors(name, :rand.uniform(3), true) end)

      :big ->
        FunWithFlags.disable(name, audit(who))
        add_actors(name, 200 + :rand.uniform(60), true)
        add_groups(name, 2)

      :no_boolean ->
        add_actors(name, 1 + :rand.uniform(3), true)
    end
  end

  # A fixed mix, spread over the alphabetical list.
  #
  defp state_for(i) do
    cond do
      i in [37, 121, 205, 263] -> :big
      rem(i, 41) == 7 -> :no_boolean
      true ->
        case rem(i * 7, 20) do
          n when n < 5 -> :on
          n when n < 11 -> :off
          n when n < 15 -> :partial_actors
          n when n < 18 -> :partial_groups
          _ -> :partial_percentage
        end
    end
  end

  defp add_actors(name, count, enabled) do
    Stream.repeatedly(&random_actor_id/0)
    |> Stream.uniq()
    |> Enum.take(count)
    |> Enum.each(fn actor_id ->
      actor = %SimpleActor{id: actor_id}
      opts = [for_actor: actor] ++ audit(Enum.random(@people))
      if enabled, do: FunWithFlags.enable(name, opts), else: FunWithFlags.disable(name, opts)
    end)
  end

  defp add_groups(name, count) do
    @groups
    |> Enum.take_random(count)
    |> Enum.each(fn group ->
      FunWithFlags.enable(name, [for_group: group] ++ audit(Enum.random(@people)))
    end)
  end

  defp random_actor_id do
    case :rand.uniform(10) do
      n when n <= 3 -> "email:" <> Enum.random(@people)
      n when n <= 7 -> "workspace:#{:rand.uniform(99_999)}"
      _ -> "user:#{:rand.uniform(999_999)}"
    end
  end

  defp maybe(probability, fun) do
    if :rand.uniform() < probability, do: fun.()
  end

  defp audit(user_id), do: [audit: [user_id: user_id]]

  # --- dates ----------------------------------------------------------

  # created_at on the flag's rows, and its audit entries spread from that
  # date towards today, in their original order.
  #
  defp backdate(name, nil, now) do
    Repo.query!("UPDATE fun_with_flags_toggles SET created_at = NULL WHERE flag_name = $1", [to_string(name)])
    Repo.query!("DELETE FROM fun_with_flags_audit_logs WHERE flag_name = $1", [to_string(name)])
    now
  end

  defp backdate(name, created_at, now) do
    name = to_string(name)
    Repo.query!("UPDATE fun_with_flags_toggles SET created_at = $1 WHERE flag_name = $2", [created_at, name])

    %{rows: ids} = Repo.query!("SELECT id FROM fun_with_flags_audit_logs WHERE flag_name = $1 ORDER BY id", [name])
    span = max(DateTime.diff(now, created_at), 1)

    ids
    |> Enum.with_index()
    |> Enum.each(fn {[id], k} ->
      # the first entry is the creation; the rest follow within the span
      offset = if k == 0, do: 0, else: min(span, k * div(span, length(ids) + 1) + :rand.uniform(3600))
      at = DateTime.add(created_at, offset, :second)
      Repo.query!("UPDATE fun_with_flags_audit_logs SET inserted_at = $1 WHERE id = $2", [at, id])
    end)
  end
end
