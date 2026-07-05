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
    assert r["reasoning_effort"] == "xhigh"
    assert r["resolved"] is True


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


def test_second_opinion_is_configured_reviewer_readonly_high():
    model_table = models()
    r = lr.resolve(table(), "second-opinion-review", model_table)
    assert r["model_ref"] == "codex_review"
    assert r["model"] == lr.resolve_model_ref(model_table, "codex_review")
    assert r["sandbox"] == "read-only"
    assert r["reasoning_effort"] == "xhigh"


def test_frontend_implement_stays_on_claude_not_bulk_coder():
    # frontend = taste, not throughput -> Claude handles the design judgement.
    model_table = models()
    r = lr.resolve(table(), "frontend-implement", model_table)
    assert r["executor"] == "self"
    assert r["model"] == lr.resolve_model_ref(model_table, "claude_orchestrator")


def test_frontend_polish_and_review_use_configured_codex_roles():
    route_table = table()
    model_table = models()
    polish = lr.resolve(route_table, "frontend-polish", model_table)
    review = lr.resolve(route_table, "frontend-review", model_table)
    assert polish["model"] == lr.resolve_model_ref(model_table, "codex_workhorse")
    assert review["model"] == lr.resolve_model_ref(model_table, "codex_review")
    assert review["sandbox"] == "read-only"        # verify by screenshot, no edits


def test_main_list(capsys):
    assert lr.main(["--list", "--file", TABLE, "--models-file", MODELS_TABLE]) == 0
    out = json.loads(capsys.readouterr().out)
    assert "bulk-mechanical-edit" in out and "deep-reasoning" in out


def test_main_resolves_model_ref(capsys):
    assert lr.main(["--model-ref", "codex_workhorse", "--models-file", MODELS_TABLE]) == 0
    assert capsys.readouterr().out.strip() == lr.resolve_model_ref(models(), "codex_workhorse")


def test_main_rejects_unknown_model_ref():
    assert lr.main(["--model-ref", "missing", "--models-file", MODELS_TABLE]) == 2


def test_main_requires_archetype_or_list():
    assert lr.main(["--file", TABLE, "--models-file", MODELS_TABLE]) == 2
