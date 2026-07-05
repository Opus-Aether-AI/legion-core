import importlib.util
import json
import os

HERE = os.path.dirname(__file__)
_PATH = os.path.join(HERE, "..", "..", "legion-router", "scripts", "legion-route.py")
_spec = importlib.util.spec_from_file_location("legion_route", _PATH)
lr = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(lr)

TABLE = os.path.join(HERE, "..", "..", "legion-router", "config", "routing.toml")


def test_resolve_known_archetype():
    r = lr.resolve(lr.load_table(TABLE), "bulk-mechanical-edit")
    assert r["executor"] == "codex"
    assert r["model"] == "gpt-5.5"
    assert r["sandbox"] == "workspace-write"
    assert r["reasoning_effort"] == "xhigh"
    assert r["resolved"] is True


def test_load_table_without_tomllib_uses_stdlib_fallback(monkeypatch):
    monkeypatch.setattr(lr, "tomllib", None)
    table = lr.load_table(TABLE)
    r = lr.resolve(table, "final-review")
    assert table["targets"]["codex_share"] == 0.5
    assert r["resolved"] is True
    assert r["executor"] == "codex"
    assert r["model"] == "gpt-5.5"
    assert r["sandbox"] == "read-only"


def test_resolve_unknown_falls_to_defaults():
    r = lr.resolve(lr.load_table(TABLE), "does-not-exist")
    assert r["resolved"] is False
    assert r["executor"] == "self"


def test_deep_reasoning_stays_on_opus():
    r = lr.resolve(lr.load_table(TABLE), "deep-reasoning")
    assert r["executor"] == "self" and r["model"] == "opus"


def test_second_opinion_is_gpt55_readonly_high():
    r = lr.resolve(lr.load_table(TABLE), "second-opinion-review")
    assert r["model"] == "gpt-5.5"
    assert r["sandbox"] == "read-only"
    assert r["reasoning_effort"] == "xhigh"


def test_frontend_implement_stays_on_opus_not_bulk_coder():
    # frontend = taste, not throughput -> Opus handles the design judgement.
    r = lr.resolve(lr.load_table(TABLE), "frontend-implement")
    assert r["executor"] == "self" and r["model"] == "opus"


def test_frontend_polish_and_review_use_gpt55_not_54():
    table = lr.load_table(TABLE)
    polish = lr.resolve(table, "frontend-polish")
    review = lr.resolve(table, "frontend-review")
    assert polish["model"] == "gpt-5.5"
    assert review["model"] == "gpt-5.5"
    assert review["sandbox"] == "read-only"        # verify by screenshot, no edits


def test_main_list(capsys):
    assert lr.main(["--list", "--file", TABLE]) == 0
    out = json.loads(capsys.readouterr().out)
    assert "bulk-mechanical-edit" in out and "deep-reasoning" in out


def test_main_accepts_demo_task_hint(capsys):
    assert lr.main(["implement-feature", "--task", "Build the demo workflow", "--file", TABLE]) == 0
    out = json.loads(capsys.readouterr().out)
    assert out["archetype"] == "implement-feature"
    assert out["resolved"] is True


def test_main_requires_archetype_or_list():
    assert lr.main(["--file", TABLE]) == 2
