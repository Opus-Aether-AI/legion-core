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
    assert r["reasoning_effort"] == "max"   # GPT-5.6 runs at max
    assert r["resolved"] is True


def test_load_table_without_tomllib_uses_stdlib_fallback(monkeypatch):
    monkeypatch.setattr(lr, "tomllib", None)
    table = lr.load_table(TABLE)
    r = lr.resolve(table, "final-review")
    assert table["targets"]["codex_share"] == 0.5
    assert r["resolved"] is True
    assert r["executor"] == "codex"
    assert r["model"] == "gpt-5.6-sol"
    assert r["sandbox"] == "read-only"


def test_resolve_unknown_falls_to_defaults():
    model_table = models()
    r = lr.resolve(table(), "does-not-exist", model_table)
    assert r["resolved"] is False
    assert r["executor"] == "self"
    assert r["model"] == lr.resolve_model_ref(model_table, "claude_orchestrator")


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


def test_frontend_runs_on_grok_in_cursor():
    # Frontend is taste + verified-by-screenshot, so the polish/review pass runs on
    # Grok 4.5 in Cursor (Cursor-native), not the bulk coder.
    route_table = table()
    model_table = models()
    polish = lr.resolve(route_table, "frontend-polish", model_table)
    review = lr.resolve(route_table, "frontend-review", model_table)
    assert polish["executor"] == "cursor"
    assert polish["model"] == lr.resolve_model_ref(model_table, "cursor_default")
    assert review["executor"] == "cursor"
    assert review["sandbox"] == "read-only"        # verify by screenshot, no edits


def test_main_list(capsys):
    assert lr.main(["--list", "--file", TABLE, "--models-file", MODELS_TABLE]) == 0
    out = json.loads(capsys.readouterr().out)
    assert "bulk-mechanical-edit" in out and "deep-reasoning" in out


def test_main_accepts_demo_task_hint(capsys):
    assert lr.main(["implement-feature", "--task", "Build the demo workflow", "--file", TABLE, "--models-file", MODELS_TABLE]) == 0
    out = json.loads(capsys.readouterr().out)
    assert out["archetype"] == "implement-feature"
    assert out["resolved"] is True


def test_main_resolves_model_ref(capsys):
    assert lr.main(["--model-ref", "codex_workhorse", "--models-file", MODELS_TABLE]) == 0
    assert capsys.readouterr().out.strip() == lr.resolve_model_ref(models(), "codex_workhorse")


def test_model_ref_lookup_does_not_require_tomllib(monkeypatch, capsys):
    monkeypatch.setattr(lr, "tomllib", None)

    assert lr.main(["--model-ref", "cursor_default", "--models-file", MODELS_TABLE]) == 0
    assert capsys.readouterr().out.strip() == "cursor-grok-4.5-high"


def test_main_rejects_unknown_model_ref():
    assert lr.main(["--model-ref", "missing", "--models-file", MODELS_TABLE]) == 2


def test_main_requires_archetype_or_list():
    assert lr.main(["--file", TABLE, "--models-file", MODELS_TABLE]) == 2


# ── new-catalog policy: Fable / GPT-5.6 / Grok only ──────────────────────
_ALLOWED_FAMILIES = ("claude-fable", "gpt-", "grok-")
_FORBIDDEN_MODELS = ("opus", "sonnet", "haiku", "composer", "minimax", "kimi",
                     "gemini", "glm", "muse", "nemotron", "qwen")


def test_catalog_is_only_fable_gpt_grok():
    m = models()
    assert m, "models.toml must have a [models] table"
    for role, model in m.items():
        low = model.lower()
        assert not any(bad in low for bad in _FORBIDDEN_MODELS), f"{role}={model} is not Fable/GPT/Grok"
        assert any(fam in low for fam in _ALLOWED_FAMILIES), f"{role}={model} is not an allowed family"
    for gone in ("claude_flagship", "claude_sonnet", "claude_fast", "cursor_composer", "auto_tier_haiku"):
        assert gone not in m, f"removed role {gone} is still present"


def test_effort_policy_fable_high_gpt_max_grok_high():
    t, m = table(), models()
    for a in ("orchestrate", "architecture-decision", "deep-reasoning", "frontend-implement"):
        r = lr.resolve(t, a, m)
        assert r["executor"] == "self" and r["reasoning_effort"] == "high", (a, r)
    for a in ("implement-feature", "fix-bug", "cheap-bulk", "hard-bug", "final-review", "security-review"):
        r = lr.resolve(t, a, m)
        assert r["executor"] == "codex" and r["reasoning_effort"] == "max", (a, r)
    for a in ("frontend-polish", "frontend-review", "second-opinion-review", "cross-model-tiebreak"):
        r = lr.resolve(t, a, m)
        assert r["executor"] == "cursor" and r["reasoning_effort"] == "high", (a, r)


def test_hard_and_review_use_top_gpt_sol():
    t, m = table(), models()
    sol = lr.resolve_model_ref(m, "codex_review")
    assert sol == "gpt-5.6-sol"
    for a in ("hard-bug", "final-review", "security-review"):
        assert lr.resolve(t, a, m)["model"] == sol, a


def test_cheap_bulk_uses_cheapest_gpt_tier():
    t, m = table(), models()
    r = lr.resolve(t, "cheap-bulk", m)
    assert r["model_ref"] == "codex_cheap"
    assert r["model"] == lr.resolve_model_ref(m, "codex_cheap") == "gpt-5.6-luna"
