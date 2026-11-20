"""Run guards (issue #218 steps 3-5): executor health, spending caps, and
model-table currency.

Model ids never appear literally here: test_model_config_centralized allows them
only in models.toml and costs.json, so provider-list fixtures are built from the
live catalog at test time.
"""

import importlib.util
import json
import os
import sys
import time
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "legion-observability" / "scripts"))

import legion_executor_health as health  # noqa: E402


def _load(name, rel):
    spec = importlib.util.spec_from_file_location(name, ROOT / rel)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


models_cli = _load("legion_models", "legion-router/scripts/legion-models.py")
budget = _load("legion_budget", "legion-router/scripts/legion-budget.py")
route = _load("legion_route_for_guards", "legion-router/scripts/legion-route.py")
CATALOG = route.load_models(str(ROOT / "legion-router" / "config" / "models.toml"))


# ── executor health ────────────────────────────────────────────────────


def test_classify_text_separates_quota_and_login_from_ordinary_errors():
    assert health.classify_text("You've hit your usage limit") == "no_quota"
    assert health.classify_text("Error: 429 Too Many Requests") == "no_quota"
    assert health.classify_text("Invalid API key · Please run /login") == "logged_out"
    assert health.classify_text("failed to refresh OAuth tokens") == "logged_out"
    assert health.classify_text("AssertionError: expected 3 got 4") == ""
    assert health.classify_text("") == ""


def test_fresh_records_decide_and_stale_ok_records_are_not_evidence(tmp_path):
    path = str(tmp_path / "h.json")
    now = time.time()
    health.record("codex", "unavailable", "no_quota", "x", path=path, now=now)
    assert health.evaluate("codex", path=path, now=now + 10)["available"] is False
    # Past recheck_after a quota outage is re-probed; with no probe allowed it
    # is no longer evidence either way.
    later = health.evaluate("codex", path=path, now=now + 2 * 3600, probe_stale=False)
    assert later["available"] is True and later["fresh"] is False
    health.record("claude", "ok", path=path, now=now)
    assert health.evaluate("claude", path=path, now=now + 10**6)["available"] is True


def test_missing_record_is_available_without_probing(tmp_path, monkeypatch):
    def boom(*_args, **_kwargs):
        raise AssertionError("routing must not probe an executor that has no record")

    monkeypatch.setattr(health, "probe", boom)
    verdict = health.evaluate("codex", path=str(tmp_path / "h.json"))
    assert verdict["available"] is True and verdict["source"] == "none"


def test_observe_marks_ok_on_success_and_only_known_outages_on_failure(tmp_path):
    path = str(tmp_path / "h.json")
    assert health.observe("cursor", "failed", texts=["SyntaxError in task"], path=path) is None
    entry = health.observe("cursor", "failed", reason_hint="missing_key", path=path)
    assert entry["status"] == "unavailable" and entry["reason"] == "missing_key"
    assert health.observe("cursor", "ok", path=path)["status"] == "ok"
    entry = health.observe("codex-review", "failed", default_reason="probe_failed", path=path)
    assert entry["reason"] == "probe_failed"
    assert health.load(path)["executors"]["codex"]["reason"] == "probe_failed"


def test_record_rejects_unknown_reasons_and_names(tmp_path):
    path = str(tmp_path / "h.json")
    with pytest.raises(health.HealthError):
        health.record("codex", "unavailable", "sleepy", path=path)
    with pytest.raises(health.HealthError):
        health.record("../codex", "ok", path=path)


def test_pick_skips_unhealthy_and_unconfigured_executors(tmp_path):
    path = str(tmp_path / "h.json")
    health.record("claude", "unavailable", "no_quota", path=path)
    choice = health.pick(["codex"], order=["codex", "claude", "nonexistent", "opencode"], path=path)
    assert choice["executor"] == "opencode"
    assert {"executor": "claude", "reason": "no_quota"} in choice["skipped"]
    assert {"executor": "nonexistent", "reason": "no_model_role"} in choice["skipped"]


def test_fallback_order_reads_routing_toml_and_env_override(monkeypatch):
    assert health.fallback_order()[0] == "claude"
    monkeypatch.setenv("LEGION_HEALTH_FALLBACK_ORDER", "opencode, claude")
    assert health.fallback_order() == ["opencode", "claude"]


def test_opencode_probe_names_the_key_file_when_openrouter_has_no_key(tmp_path, monkeypatch):
    fake = tmp_path / "opencode"
    fake.write_text("#!/bin/sh\nexit 0\n")
    fake.chmod(0o755)
    env = {
        "HOME": str(tmp_path),
        "PATH": os.environ.get("PATH", ""),
        "OPENCODE_BIN": str(fake),
        "LEGION_OPENROUTER_KEY_FILE": str(tmp_path / "or.key"),
    }
    result = health.probe("opencode", env)
    if not CATALOG["opencode_default"].startswith("openrouter/"):
        pytest.skip("opencode_default is not an OpenRouter role")
    assert result["status"] == "unavailable" and result["reason"] == "missing_key"
    assert str(tmp_path / "or.key") in result["detail"]
    (tmp_path / "or.key").write_text("placeholder\n")
    assert health.probe("opencode", env)["status"] == "ok"


# ── spending caps ──────────────────────────────────────────────────────


def test_budget_caps_precedence_and_zero_disables():
    caps = budget.caps({})
    assert caps["sources"]["run_usd"] == "routing.toml" and caps["run_usd"] > 0
    caps = budget.caps({"LEGION_RUN_BUDGET_USD": "2", "LEGION_DAY_BUDGET_USD": "nonsense"})
    assert caps["run_usd"] == 2.0 and caps["sources"]["day_usd"] == "routing.toml"
    assert budget.run_status("ok", 5, {"LEGION_RUN_BUDGET_USD": "0"}) == "ok"
    assert budget.run_status("ok", 5, {"LEGION_RUN_BUDGET_USD": "4"}) == "over_budget"
    assert budget.run_status("failed", 5, {"LEGION_RUN_BUDGET_USD": "4"}) == "failed"


def test_day_spend_counts_delegated_spans_once(tmp_path):
    day = "2026-11-20"
    home = tmp_path / "legion"
    for project, rows in {
        "a": [
            {"executor": "claude", "cost_usd": 1.5},
            {"executor": "codex-review", "cost_usd": 0.5},
            {"executor": "orchestrator", "cost_usd": 2.0},
        ],
        "b": [
            {"executor": "opencode", "cost_usd": 0.25},
            {"executor": "opus-baseline", "cost_usd": 9, "artifacts": {"synthetic_primary_baseline": True}},
        ],
    }.items():
        spans = home / "projects" / project / "spans"
        spans.mkdir(parents=True)
        (spans / f"{day}.jsonl").write_text(
            "".join(json.dumps({"schema": "legion.span.v1", **row}) + "\n" for row in rows)
        )
    env = {"HOME": str(tmp_path), "LEGION_HOME": str(home),
           "LEGION_TELEMETRY_DIR": str(home / "projects" / "a" / "spans")}
    spend = budget.day_spend(day, env)
    assert spend["spent_usd"] == 2.25
    assert spend["by_executor"] == {"claude": 1.5, "codex": 0.5, "opencode": 0.25}
    assert spend["span_files"] == 2


# ── model-table currency ───────────────────────────────────────────────


def _provider_fixture(tmp_path, drop_role=None):
    """Provider lists that contain every catalog id, optionally minus one role's."""
    dropped = CATALOG.get(drop_role) if drop_role else None
    md = {}
    openrouter = []
    for model in CATALOG.values():
        if model == dropped:
            continue
        provider, listed = models_cli.provider_of(model)
        if provider == "openrouter":
            openrouter.append({"id": listed})
        elif provider in models_cli.MODELS_DEV_PROVIDERS:
            md.setdefault(provider, {"models": {}})["models"][listed] = {}
    (tmp_path / "md.json").write_text(json.dumps(md))
    (tmp_path / "or.json").write_text(json.dumps({"data": openrouter}))
    return {
        "LEGION_MODELS_DEV_URL": (tmp_path / "md.json").as_uri(),
        "LEGION_OPENROUTER_MODELS_URL": (tmp_path / "or.json").as_uri(),
    }


def test_provider_of_maps_each_catalog_family():
    for role, model in CATALOG.items():
        provider, listed = models_cli.provider_of(model)
        assert provider != "unknown", role
        if model.startswith("openrouter/"):
            assert provider == "openrouter" and not listed.startswith("openrouter/")
    assert models_cli.provider_of(CATALOG["cursor_default"])[0] == "cursor"


def test_models_check_reports_current_missing_unverifiable_and_unchecked(tmp_path):
    cache = str(tmp_path / "cache")
    report = models_cli.check(CATALOG, cache)
    assert report["counts"].get("unchecked", 0) > 0 and report["missing"] == []

    assert models_cli.fetch(cache, _provider_fixture(tmp_path)) == {"models-dev": "", "openrouter": ""}
    report = models_cli.check(CATALOG, cache)
    assert report["missing"] == []
    assert set(report["counts"]) <= {"current", "unverifiable"}
    assert report["sources"]["openrouter"]["stale"] is False

    models_cli.fetch(cache, _provider_fixture(tmp_path, drop_role="claude_frontier"))
    report = models_cli.check(CATALOG, cache)
    missing = {row["role"] for row in report["missing"]}
    assert "claude_frontier" in missing


def test_models_check_cli_exit_codes(tmp_path, monkeypatch, capsys):
    monkeypatch.setenv("LEGION_MODELS_CACHE_DIR", str(tmp_path / "cache"))
    for key, value in _provider_fixture(tmp_path).items():
        monkeypatch.setenv(key, value)
    assert models_cli.main(["check", "--fetch", "--json"]) == 0
    for key, value in _provider_fixture(tmp_path, drop_role="opencode_default").items():
        monkeypatch.setenv(key, value)
    assert models_cli.main(["check", "--fetch"]) == 1
    assert "missing" in capsys.readouterr().out
    # A failed fetch keeps the last good list and says so.
    monkeypatch.setenv("LEGION_OPENROUTER_MODELS_URL", (tmp_path / "absent.json").as_uri())
    models_cli.main(["check", "--fetch", "--json"])
    report = json.loads(capsys.readouterr().out)
    assert "fetch_error" in report["sources"]["openrouter"]
    assert report["sources"]["openrouter"]["fetched_at"] is not None


def test_a_passing_probe_does_not_clear_a_fresh_outage_a_run_recorded(tmp_path, monkeypatch):
    path = str(tmp_path / "h.json")
    now = time.time()
    health.record("claude", "unavailable", "no_quota", "usage limit", "run", path=path, now=now)
    monkeypatch.setattr(health, "probe", lambda *_a, **_k: {"status": "ok", "reason": "", "detail": "cli present"})
    verdict = health.evaluate("claude", force_probe=True, path=path, now=now + 60)
    assert verdict["available"] is False and verdict["reason"] == "no_quota"
    assert health.load(path)["executors"]["claude"]["status"] == "unavailable"
    # A probe that FINDS an outage still wins over a run-learned record.
    monkeypatch.setattr(
        health, "probe", lambda *_a, **_k: {"status": "unavailable", "reason": "logged_out", "detail": "x"}
    )
    assert health.evaluate("claude", force_probe=True, path=path, now=now + 60)["reason"] == "logged_out"


def test_opencode_probe_accepts_an_openrouter_key_stored_by_opencode(tmp_path):
    if not CATALOG["opencode_default"].startswith("openrouter/"):
        pytest.skip("opencode_default is not an OpenRouter role")
    fake = tmp_path / "opencode"
    fake.write_text("#!/bin/sh\nexit 0\n")
    fake.chmod(0o755)
    store = tmp_path / "data" / "opencode"
    store.mkdir(parents=True)
    (store / "auth.json").write_text(json.dumps({"openrouter": {"type": "api", "key": "placeholder"}}))
    env = {
        "HOME": str(tmp_path),
        "PATH": os.environ.get("PATH", ""),
        "OPENCODE_BIN": str(fake),
        "XDG_DATA_HOME": str(tmp_path / "data"),
        "LEGION_OPENROUTER_KEY_FILE": str(tmp_path / "absent.key"),
    }
    assert health.probe("opencode", env)["status"] == "ok"
