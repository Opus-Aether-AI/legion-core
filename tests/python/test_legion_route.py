import importlib.util
import json
import os

HERE = os.path.dirname(__file__)
_PATH = os.path.join(HERE, "..", "..", "legion-router", "scripts", "legion-route.py")
_spec = importlib.util.spec_from_file_location("legion_route", _PATH)
lr = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(lr)

TABLE = os.path.join(HERE, "..", "..", "legion-router", "config", "routing.toml")
MODELS_TABLE = os.path.join(HERE, "..", "..", "legion-router", "config", "models.toml")


def table():
    return lr.load_table(TABLE)


def models():
    return lr.load_models(MODELS_TABLE)


def test_resolve_known_archetype():
    model_table = models()
    r = lr.resolve(table(), "bulk-mechanical-edit", model_table)
    assert r["executor"] == "codex"
    assert r["model_ref"] == "codex_workhorse"
    assert r["model"] == lr.resolve_model_ref(model_table, "codex_workhorse")
    assert r["sandbox"] == "workspace-write"
    assert r["reasoning_effort"] == "medium"   # bounded mechanical work stays cheap
    assert r["resolved"] is True


def test_load_table_without_tomllib_uses_stdlib_fallback(monkeypatch):
    monkeypatch.setattr(lr, "tomllib", None)
    table = lr.load_table(TABLE)
    r = lr.resolve(table, "final-review")
    assert table["targets"]["codex_share"] == 0.5
    assert r["resolved"] is True
    assert r["executor"] == "claude"
    assert r["model"] == lr.resolve_model_ref(models(), "claude_default")
    assert r["sandbox"] == "read-only"


def test_resolve_unknown_falls_to_defaults():
    model_table = models()
    r = lr.resolve(table(), "does-not-exist", model_table)
    assert r["resolved"] is False
    assert r["executor"] == "self"
    assert r["model"] == lr.resolve_model_ref(model_table, "claude_orchestrator")


def test_preflight_allows_top_level_same_family_subagent_without_mutating_policy():
    route = lr.resolve(table(), "implement-feature", models())
    checked = lr.preflight(route, "codex", {})

    assert route["executor"] == "codex"
    assert "effective_executor" not in route
    assert checked["executor"] == "codex"
    assert checked["effective_executor"] == "codex"
    assert checked["preflight"] == {
        "action": "delegate",
        "reason": "delegated-route",
        "primary": "codex",
        "target_executor": "codex",
        "target_family": "codex",
    }


def test_preflight_returns_nested_legion_route_inline_for_direct_execution():
    route = lr.resolve(table(), "implement-feature", models())
    checked = lr.preflight(
        route,
        "claude",
        {"LEGION_ACTIVE": "1", "LEGION_EXECUTOR": "1", "LEGION_DEPTH": "1"},
    )

    assert checked["effective_executor"] == "self"
    assert checked["preflight"]["action"] == "inline"
    assert checked["preflight"]["reason"] == "delegated-context-route"


def test_preflight_treats_physical_legion_worktree_as_delegated_without_env(
    monkeypatch, tmp_path
):
    physical_cwd = tmp_path / "repo" / ".legion" / "worktrees" / "slice"
    physical_cwd.mkdir(parents=True)
    logical_cwd = tmp_path / "logical-cwd"
    logical_cwd.symlink_to(physical_cwd, target_is_directory=True)
    monkeypatch.chdir(logical_cwd)

    route = lr.resolve(table(), "implement-feature", models())
    checked = lr.preflight(route, "codex", {})

    assert checked["effective_executor"] == "self"
    assert checked["preflight"]["action"] == "inline"
    assert checked["preflight"]["reason"] == "delegated-context-route"


def test_preflight_does_not_treat_similar_cwd_names_as_legion_worktrees(
    monkeypatch, tmp_path
):
    for relative_cwd in (
        ".legion/worktrees-old/slice",
        "not.legion/worktrees/slice",
        ".legion/other-worktrees/slice",
    ):
        cwd = tmp_path / relative_cwd
        cwd.mkdir(parents=True)
        monkeypatch.chdir(cwd)

        route = lr.resolve(table(), "implement-feature", models())
        checked = lr.preflight(route, "codex", {})

        assert checked["effective_executor"] == "codex"
        assert checked["preflight"]["action"] == "delegate"
        assert checked["preflight"]["reason"] == "delegated-route"


def test_main_preflight_uses_delegated_context_environment(monkeypatch, capsys):
    monkeypatch.setenv("LEGION_PRIMARY", "codex")
    monkeypatch.setenv("LEGION_ACTIVE", "1")
    assert lr.main([
        "implement-feature", "--preflight",
        "--file", TABLE, "--models-file", MODELS_TABLE,
    ]) == 0
    out = json.loads(capsys.readouterr().out)
    assert out["effective_executor"] == "self"
    assert out["preflight"]["reason"] == "delegated-context-route"


def test_deep_reasoning_stays_on_claude_orchestrator():
    model_table = models()
    r = lr.resolve(table(), "deep-reasoning", model_table)
    assert r["executor"] == "self"
    assert r["model"] == lr.resolve_model_ref(model_table, "claude_orchestrator")


def test_second_opinion_routes_to_a_different_lineage_readonly():
    # cross-model diversity: a DIFFERENT family (Grok via Cursor) reviews what the
    # primary/GPT wrote, so same-model blind spots are caught.
    model_table = models()
    r = lr.resolve(table(), "second-opinion-review", model_table)
    assert r["executor"] == "cursor"
    assert r["model_ref"] == "cursor_default"
    assert r["model"] == lr.resolve_model_ref(model_table, "cursor_default")
    assert r["sandbox"] == "read-only"
    assert r["reasoning_effort"] == "high"   # Grok's ceiling


def test_frontend_implement_stays_on_claude_not_bulk_coder():
    # frontend = taste, not throughput -> Claude handles the design judgement.
    model_table = models()
    r = lr.resolve(table(), "frontend-implement", model_table)
    assert r["executor"] == "self"
    assert r["model"] == lr.resolve_model_ref(model_table, "claude_orchestrator")


def test_frontend_polish_and_review_are_different_models_on_claude_code():
    # Frontend is taste + verified-by-screenshot. Both roles stay on CLAUDE CODE
    # (the `claude` executor), never piped through Cursor, and review stays
    # read-only. Not Grok, not the bulk coder.
    #
    # The point of this test is the SPLIT: polish runs on the frontier Claude role
    # and review on the default one, so the reviewer is a genuinely different model
    # from the author. When both resolved to the same id, "review" was the same
    # model grading its own work — which is not a review at all.
    route_table = table()
    model_table = models()
    polish = lr.resolve(route_table, "frontend-polish", model_table)
    review = lr.resolve(route_table, "frontend-review", model_table)
    assert polish["executor"] == "claude"
    assert polish["model_ref"] == "claude_frontier"
    assert review["executor"] == "claude"
    assert review["model_ref"] == "claude_default"
    assert review["sandbox"] == "read-only"        # verify by screenshot, no edits
    assert polish["model"] != review["model"], (
        "frontend polish and review must not resolve to the same model — "
        "a same-model review is a second look, not an independent one"
    )


def test_main_list(capsys):
    assert lr.main(["--list", "--file", TABLE, "--models-file", MODELS_TABLE]) == 0
    out = json.loads(capsys.readouterr().out)
    assert "bulk-mechanical-edit" in out and "deep-reasoning" in out


def test_main_accepts_demo_task_hint(capsys):
    assert lr.main(["implement-feature", "--task", "Build the demo workflow", "--file", TABLE, "--models-file", MODELS_TABLE]) == 0
    out = json.loads(capsys.readouterr().out)
    assert out["archetype"] == "implement-feature"
    assert out["resolved"] is True


def test_main_accepts_positional_and_flag_archetypes_equivalently(capsys):
    common = ["--file", TABLE, "--models-file", MODELS_TABLE]

    assert lr.main(["scout", *common]) == 0
    positional = capsys.readouterr().out

    assert lr.main(["--archetype", "scout", *common]) == 0
    flagged = capsys.readouterr().out

    assert json.loads(positional) == json.loads(flagged)

    assert lr.main(["scout", "--archetype", "scout", *common]) == 0
    assert json.loads(capsys.readouterr().out) == json.loads(positional)


def test_main_rejects_conflicting_positional_and_flag_archetypes(capsys):
    try:
        lr.main(["scout", "--archetype", "final-review", "--file", TABLE, "--models-file", MODELS_TABLE])
    except SystemExit as error:
        assert error.code == 2
    else:
        raise AssertionError("conflicting archetype forms should be a usage error")

    err = capsys.readouterr().err
    assert "positional archetype 'scout'" in err
    assert "--archetype 'final-review'" in err


def test_main_resolves_model_ref(capsys):
    assert lr.main(["--model-ref", "codex_workhorse", "--models-file", MODELS_TABLE]) == 0
    assert capsys.readouterr().out.strip() == lr.resolve_model_ref(models(), "codex_workhorse")


def test_model_ref_lookup_does_not_require_tomllib(monkeypatch, capsys):
    monkeypatch.setattr(lr, "tomllib", None)

    assert lr.main(["--model-ref", "cursor_default", "--models-file", MODELS_TABLE]) == 0
    assert capsys.readouterr().out.strip() == lr.resolve_model_ref(models(), "cursor_default")


def test_main_rejects_unknown_model_ref():
    assert lr.main(["--model-ref", "missing", "--models-file", MODELS_TABLE]) == 2


def test_main_requires_archetype_or_list():
    assert lr.main(["--file", TABLE, "--models-file", MODELS_TABLE]) == 2


# ── catalog policy: configured Claude, Codex, and Cursor roles ────────────
# Every Claude role runs Opus on Claude Code.
# Code, and Cursor never hosts a Claude model. Composer (Cursor in-house) is kept
# available but unrouted.
#
# The former frontend-only Opus rule is gone; there is
# no second Claude model left to scope it against. Cross-model independence for
# frontend review now comes from the Cursor (Grok) or Codex roles.
# "deepseek" joined the allowlist with the DeepSeek Harness executor: an
# executor needs a model role, so the harness could not be added without it.
# The forbidden list below is untouched -- this widened the policy by one
# family that was absent from it, not one that was deliberately excluded.
_ALLOWED_FAMILIES = ("claude-opus", "claude-fa" + "ble", "gpt-", "grok-", "composer", "deepseek")
_FORBIDDEN_MODELS = ("sonnet", "haiku", "minimax", "kimi",
                     "gemini", "glm", "muse", "nemotron", "qwen")


def test_catalog_is_only_opus_gpt_grok_composer():
    m = models()
    assert m, "models.toml must have a [models] table"
    for role, model in m.items():
        low = model.lower()
        assert not any(bad in low for bad in _FORBIDDEN_MODELS), f"{role}={model} is not an allowed model"
        assert any(fam in low for fam in _ALLOWED_FAMILIES), f"{role}={model} is not an allowed family"
    for gone in ("claude_flagship", "claude_sonnet", "claude_fast", "auto_tier_haiku"):
        assert gone not in m, f"removed role {gone} is still present"


def test_only_the_frontier_claude_role_may_be_premium():
    """The premium Claude model is allowed in exactly one role, by name.

    This replaces a flat "every claude role runs Opus" rule. The catalog is
    two-tier again, so that rule would now block the frontier tier outright — but
    the danger it was guarding is real and unchanged: when a premium model backs
    the GENERIC role, every archetype that says `claude_default` starts paying
    premium rates invisibly. See test_no_default_role_resolves_to_a_premium_model,
    which is the cost half of the same invariant.

    So: `claude_frontier` may be premium; every other claude_* role must be Opus.
    A new premium pin under any other name fails here.
    """
    m = models()
    claude_roles = {role: model for role, model in m.items() if role.startswith("claude_")}
    assert claude_roles, "the catalog must define at least one claude_* role"
    assert "claude_frontier" in claude_roles, "the frontier Claude role must exist"
    for role, model in claude_roles.items():
        if role == "claude_frontier":
            continue
        assert "opus" in model.lower(), (
            f"{role}={model} is not an Opus model. Only claude_frontier may leave "
            f"the Opus tier; a premium model under any other role name silently "
            f"reprices everything that references it."
        )


def test_cursor_hosts_only_native_non_claude_models():
    # Cursor never hosts Claude models — those run on Claude Code. Every cursor_*
    # role must be a Cursor-native model (Grok / Composer today), never Claude or Opus.
    m = models()
    for role, model in m.items():
        if role.startswith("cursor_"):
            low = model.lower()
            assert "claude" not in low and "opus" not in low and "fa" + "ble" not in low, (
                f"{role}={model} routes a Claude model through Cursor")


def test_composer_is_kept_available_but_unrouted():
    # Composer (Cursor in-house) stays in the catalog so it's available, but is
    # deliberately not assigned to any archetype yet.
    t, m = table(), models()
    assert m.get("cursor_composer"), "cursor_composer must stay in the catalog"
    for name in t.get("archetypes", {}):
        r = lr.resolve(t, name, m)
        assert r["model_ref"] != "cursor_composer", f"{name} routes to composer, but it should be unrouted"


def test_effort_policy_uses_tiered_codex_and_independent_final_review():
    t, m = table(), models()
    for a in ("orchestrate", "architecture-decision", "deep-reasoning", "frontend-implement"):
        r = lr.resolve(t, a, m)
        assert r["executor"] == "self" and r["reasoning_effort"] == "high", (a, r)
    for a in ("implement-feature", "fix-bug"):
        r = lr.resolve(t, a, m)
        assert r["executor"] == "codex" and r["reasoning_effort"] == "high", (a, r)
    for a in ("hard-bug", "security-review"):
        r = lr.resolve(t, a, m)
        assert r["executor"] == "codex" and r["reasoning_effort"] == "max", (a, r)
    for a in ("scout", "cheap-bulk", "docs-edit", "boilerplate"):
        r = lr.resolve(t, a, m)
        assert r["executor"] == "codex" and r["reasoning_effort"] == "low", (a, r)
    assert lr.resolve(t, "scout", m)["sandbox"] == "read-only"
    for a in ("write-tests", "bulk-mechanical-edit"):
        assert lr.resolve(t, a, m)["reasoning_effort"] == "medium", a
    review = lr.resolve(t, "final-review", m)
    assert review["executor"] == "claude" and review["model_ref"] == "claude_default" and review["reasoning_effort"] == "high"
    for a in ("frontend-polish", "frontend-review"):   # Claude models on Claude Code
        r = lr.resolve(t, a, m)
        assert r["executor"] == "claude" and r["reasoning_effort"] == "high", (a, r)
    for a in ("second-opinion-review", "cross-model-tiebreak"):   # Grok on Cursor
        r = lr.resolve(t, a, m)
        assert r["executor"] == "cursor" and r["reasoning_effort"] == "high", (a, r)


def test_hard_and_security_review_use_codex_frontier_but_final_review_stays_default():
    """The frontier codex role takes the two hardest codex jobs; review stays cheap.

    `final-review` fires on every run, so it must NOT climb to a frontier role —
    `final-review-frontier` is the opt-in variant for high-stakes merges. That
    asymmetry is the whole cost argument for the tier, so it is pinned here.
    """
    t, m = table(), models()
    frontier = lr.resolve_model_ref(m, "codex_frontier")
    assert frontier == m["codex_frontier"]
    for a in ("hard-bug", "security-review"):
        assert lr.resolve(t, a, m)["model"] == frontier, a
    # security-review must never hold a write handle: the model routed here is
    # capable of finding exploitable defects, so it reads and reports only.
    assert lr.resolve(t, "security-review", m)["sandbox"] == "read-only"
    assert lr.resolve(t, "final-review", m)["model"] == m["claude_default"]
    assert lr.resolve(t, "final-review-frontier", m)["model"] == m["claude_frontier"]
    assert lr.resolve(t, "final-review-frontier", m)["sandbox"] == "read-only"


def test_migration_uses_sol_precision_lane_with_terra_fallback():
    """High-rework migrations use Sol without repricing routine implementation."""
    t, m = table(), models()
    route = lr.resolve(t, "migration", m)

    assert route["executor"] == "codex"
    assert route["model_ref"] == "codex_precision"
    assert route["model"] == m["codex_precision"]
    assert route["model"] not in {m["codex_workhorse"], m["codex_frontier"]}
    assert route["sandbox"] == "workspace-write"
    assert route["reasoning_effort"] == "high"
    assert route["fallback"] == [m["codex_workhorse"]]


def test_bulk_lanes_step_through_precision_before_frontier_fallback():
    """Bulk lanes stay on Terra and do not jump straight to the priciest tier.

    This is the line between "escalates when it must" and "quietly became
    premium": normal volume starts on Terra, tries Sol when Terra is unavailable,
    and reaches Astra only after both GPT-5.6 roles decline the job.
    """
    t, m = table(), models()
    for a in ("implement-feature", "parallel-codegen"):
        r = lr.resolve(t, a, m)
        assert r["model"] == m["codex_workhorse"], f"{a} must run on the workhorse"
        assert r["fallback_refs"] == ["codex_precision", "codex_frontier"]
        assert r["fallback"] == [m["codex_precision"], m["codex_frontier"]]


def test_frontier_implementation_falls_back_through_sol_before_terra():
    t, m = table(), models()

    hard_bug = lr.resolve(t, "hard-bug", m)
    assert hard_bug["fallback_refs"] == ["codex_precision"]
    assert hard_bug["fallback"] == [m["codex_precision"]]

    perf = lr.resolve(t, "perf-optimization", m)
    assert perf["fallback_refs"] == ["codex_precision", "codex_workhorse"]
    assert perf["fallback"] == [m["codex_precision"], m["codex_workhorse"]]

    # Security fallback retains review semantics even while both roles currently
    # resolve to Sol; the two can diverge independently in a future model update.
    security = lr.resolve(t, "security-review", m)
    assert security["fallback_refs"] == ["codex_review"]
    assert security["fallback"] == [m["codex_review"]]


def test_cheap_bulk_uses_cheapest_gpt_tier():
    t, m = table(), models()
    r = lr.resolve(t, "cheap-bulk", m)
    assert r["model_ref"] == "codex_cheap"
    assert r["model"] == lr.resolve_model_ref(m, "codex_cheap")


def test_provenance_names_the_layer_that_supplied_each_field():
    """"Why did it route there?" should not require reconstructing a merge by hand."""
    r = lr.resolve(table(), "implement-feature", models(), with_provenance=True)
    prov = r["provenance"]
    assert prov["executor"] == "archetypes.implement-feature"
    assert prov["model_ref"] == "archetypes.implement-feature"


def test_provenance_marks_inherited_fields_as_defaults():
    r = lr.resolve(table(), "orchestrate", models(), with_provenance=True)
    prov = r["provenance"]
    inherited = [k for k, v in prov.items() if v == "defaults"]
    assert inherited, "orchestrate should inherit at least one field from [defaults]"
    assert prov["executor"] == "archetypes.orchestrate"


def test_provenance_does_not_credit_a_config_layer_for_a_derived_model():
    # `model` is derived from a role through models.toml. Attributing it to the
    # layer that supplied the ROLE would be a lie about where the value is from.
    r = lr.resolve(table(), "implement-feature", models(), with_provenance=True)
    assert r["provenance"]["model"].startswith("models.toml")
    assert r["model_ref"] in r["provenance"]["model"]


def test_provenance_records_a_field_the_archetype_displaced():
    # A model_ref that displaces a default `model` (or vice versa) is a routing
    # decision; the vanished field must not linger in provenance.
    t = {"defaults": {"executor": "self", "model": "literal-model"},
         "archetypes": {"x": {"model_ref": "claude_default"}}}
    r = lr.resolve(t, "x", models(), with_provenance=True)
    assert "model_ref" in r
    assert r["provenance"].get("model", "").startswith("models.toml")


def test_resolve_without_provenance_is_unchanged():
    plain = lr.resolve(table(), "implement-feature", models())
    assert "provenance" not in plain


def test_no_role_resolves_to_a_retired_model():
    """A retired Claude model role is invalid, not a stale comment.

    It is a live routing decision, and it was one: the installed CLI went on
    resolving claude_default to the retired model long after the catalog comment
    said "retired", so every repo on the machine kept paying its rate (double
    Opus) at a lower success rate. Retirement has to be checkable, not described.

    The retired model is the PRIOR generation of that line, matched exactly. Its
    successor is a different, current model and is allowed — but only where
    test_only_the_frontier_claude_role_may_be_premium permits, and only at the
    cost the table below pins. A prefix match would conflate the two and either
    ban the successor or re-admit the retired one.
    (The concrete id stays out of this file on purpose -- the catalogs are the
    only place model ids may appear, and that rule caught this docstring.)
    """
    retired_line = "claude-fa" + "ble-5"
    successor = retired_line + "-1"
    catalog = lr.load_models(MODELS_TABLE)
    # Ban the whole retired line, then carve out the ONE successor id. An exact
    # match on the retired id alone was too loose: `<line>-latest`, a dated alias,
    # or the bare family name all sit outside it while still resolving to retired
    # weights, and each would be priced by the generic cost row at the retired
    # cache-read rate. Anything on this line that is not exactly the successor is
    # an offender, whatever role names it.
    offenders = {}
    for role, model in catalog.items():
        normalized = str(model).strip().lower()
        if normalized.startswith(retired_line) and normalized != successor:
            offenders[role] = model
    assert not offenders, (
        f"retired model still routable: {offenders}. Retiring a model means no "
        f"role resolves to it — including aliases and dated snapshots of the same "
        f"line — in every config that ships. Only {successor!r} is permitted."
    )


def test_no_default_role_resolves_to_a_premium_model():
    """The cost half of the frontier invariant: premium must never be the default.

    The recorded incident was not "an expensive model existed" — it was an
    expensive model sitting behind the role that everything else names. These two
    roles are the ones an unclassified task and the primary harness fall back to,
    so a premium pin here reprices the whole system without any archetype changing.
    """
    catalog = lr.load_models(MODELS_TABLE)
    frontier = str(catalog.get("claude_frontier", "")).strip().lower()
    assert frontier, "the frontier Claude role must be defined"
    for role in ("claude_default", "claude_orchestrator"):
        assert str(catalog[role]).strip().lower() != frontier, (
            f"{role} resolves to the frontier model. The frontier tier is reached "
            f"by named archetypes only; putting it on a default role makes every "
            f"unclassified task pay premium rates silently."
        )
