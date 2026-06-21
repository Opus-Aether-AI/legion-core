import importlib.util
import json
import os

HERE = os.path.dirname(__file__)
_PATH = os.path.join(HERE, "..", "..", "legion-router", "scripts", "legion-optimize.py")
_spec = importlib.util.spec_from_file_location("legion_optimize", _PATH)
opt = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(opt)


def test_stats_by_arch_model_success_cost_and_percentiles():
    spans = [
        {
            "schema": "legion.span.v1",
            "executor": "codex",
            "archetype": "implement-feature",
            "model": "gpt-5.4",
            "status": "ok",
            "cost_usd": 0.1,
            "duration_ms": 100,
        },
        {
            "schema": "legion.span.v1",
            "executor": "codex",
            "archetype": "implement-feature",
            "model": "gpt-5.4",
            "status": "over_budget",
            "cost_usd": 0.2,
            "duration_ms": 200,
        },
        {
            "schema": "legion.span.v1",
            "executor": "codex",
            "archetype": "implement-feature",
            "model": "gpt-5.4",
            "status": "failed",
            "cost_usd": 0.3,
            "duration_ms": 300,
        },
        {
            "schema": "legion.span.v1",
            "executor": "codex",
            "archetype": "implement-feature",
            "model": "gpt-5.4",
            "status": "error",
            "cost_usd": 0.4,
            "duration_ms": 400,
        },
    ]
    stats = opt.stats_by_arch_model(spans)
    got = stats["implement-feature"]["gpt-5.4"]
    assert got["runs"] == 4
    assert got["success_rate"] == 0.5
    assert got["mean_cost"] == 0.25
    assert got["p50_ms"] == 250.0
    assert got["p95_ms"] == 385.0


def test_propose_accepts_cheaper_equal_or_better_model():
    stats = {
        "gpt-5.5": {"runs": 6, "success_rate": 0.8, "mean_cost": 1.0, "p50_ms": 100, "p95_ms": 200},
        "gpt-5.4": {"runs": 8, "success_rate": 0.8, "mean_cost": 0.4, "p50_ms": 90, "p95_ms": 180},
    }
    got = opt.propose(stats, "gpt-5.5")
    assert got["proposed_model"] == "gpt-5.4"
    assert got["decision"] == "accept"


def test_propose_holds_when_cheaper_model_worsens_success():
    stats = {
        "gpt-5.5": {"runs": 10, "success_rate": 0.95, "mean_cost": 1.0, "p50_ms": 100, "p95_ms": 200},
        "gpt-5.4": {"runs": 10, "success_rate": 0.94, "mean_cost": 0.5, "p50_ms": 90, "p95_ms": 180},
    }
    got = opt.propose(stats, "gpt-5.5")
    assert got["proposed_model"] == "gpt-5.4"
    assert got["decision"] == "hold"
    assert got["reason"] == "no_pareto_improvement"


def test_propose_a_cheaper_but_worse_model_does_not_block_a_valid_pareto_win():
    # current=expensive; A is cheaper + equal success (valid Pareto accept); B is even
    # cheaper but worse-on-success (within slack pool). The optimizer must accept A,
    # not let B (cheapest of the pool) block it into a hold.
    stats = {
        "gpt-5.5": {"runs": 8, "success_rate": 0.90, "mean_cost": 1.0, "p50_ms": 100, "p95_ms": 200},
        "gpt-5.4": {"runs": 8, "success_rate": 0.90, "mean_cost": 0.5, "p50_ms": 90, "p95_ms": 180},
        "minimax": {"runs": 8, "success_rate": 0.89, "mean_cost": 0.3, "p50_ms": 80, "p95_ms": 160},
    }
    got = opt.propose(stats, "gpt-5.5", bar_slack=0.02)
    assert got["decision"] == "accept", got
    assert got["proposed_model"] == "gpt-5.4"  # the valid Pareto win, not the cheaper-worse minimax


def test_propose_holds_with_insufficient_samples():
    stats = {
        "gpt-5.5": {"runs": 4, "success_rate": 1.0, "mean_cost": 1.0, "p50_ms": 100, "p95_ms": 200},
        "gpt-5.4": {"runs": 3, "success_rate": 1.0, "mean_cost": 0.5, "p50_ms": 90, "p95_ms": 180},
    }
    got = opt.propose(stats, "gpt-5.5")
    assert got["decision"] == "hold"
    assert got["reason"] == "insufficient_samples"


def test_propose_holds_when_current_is_already_cheapest_clearing_bar():
    stats = {
        "gpt-5.5": {"runs": 7, "success_rate": 0.9, "mean_cost": 0.4, "p50_ms": 100, "p95_ms": 200},
        "gpt-5.4": {"runs": 7, "success_rate": 0.92, "mean_cost": 0.5, "p50_ms": 90, "p95_ms": 180},
    }
    got = opt.propose(stats, "gpt-5.5")
    assert got["proposed_model"] == "gpt-5.5"
    assert got["decision"] == "hold"
    assert got["reason"] == "already_optimal"


def test_load_spans_filters_wrong_schema_self_executor_and_missing_archetype(tmp_path):
    spans = tmp_path / "2026-06-15.jsonl"
    rows = [
        {
            "schema": "legion.span.v1",
            "executor": "codex",
            "archetype": "implement-feature",
            "model": "gpt-5.4",
            "status": "ok",
        },
        {
            "schema": "legion.span.v1",
            "executor": "cursor",
            "archetype": "implement-feature",
            "model": "gpt-5",
            "status": "ok",
        },
        {
            "schema": "legion.span.v1",
            "executor": "self",
            "archetype": "implement-feature",
            "model": "opus",
            "status": "ok",
        },
        {
            "schema": "legion.span.v1",
            "executor": "codex",
            "archetype": "",
            "model": "gpt-5.4",
            "status": "ok",
        },
        {
            "schema": "other",
            "executor": "codex",
            "archetype": "implement-feature",
            "model": "gpt-5.4",
            "status": "ok",
        },
    ]
    spans.write_text("\n".join(json.dumps(row) for row in rows) + "\nNOT JSON\n")
    got = opt.load_spans(tmp_path)
    assert got == [rows[0], rows[1]]


def test_optimize_skips_self_routing_and_includes_stats_only_arch():
    spans = []
    for _ in range(5):
        spans.append(
            {
                "schema": "legion.span.v1",
                "executor": "codex",
                "archetype": "stats-only",
                "model": "gpt-5.4",
                "status": "ok",
                "cost_usd": 0.2,
                "duration_ms": 100,
            }
        )
    routing = {
        "deep-reasoning": {"executor": "self", "model": "opus"},
        "implement-feature": {"executor": "codex", "model": "gpt-5.5"},
    }
    got = opt.optimize(spans, routing)
    assert "deep-reasoning" not in got
    assert "implement-feature" in got
    assert "stats-only" in got
    assert got["stats-only"]["decision"] == "accept"
    assert got["stats-only"]["proposed_model"] == "gpt-5.4"


def test_optimize_does_not_accept_cross_executor_as_model_only_change():
    spans = []
    for _ in range(5):
        spans.append(
            {
                "schema": "legion.span.v1",
                "executor": "codex",
                "archetype": "implement-feature",
                "model": "gpt-5.4",
                "status": "ok",
                "cost_usd": 1.0,
                "duration_ms": 100,
            }
        )
        spans.append(
            {
                "schema": "legion.span.v1",
                "executor": "cursor",
                "archetype": "implement-feature",
                "model": "cursor-auto",
                "status": "ok",
                "cost_usd": 0.1,
                "duration_ms": 100,
            }
        )
    routing = {"implement-feature": {"executor": "codex", "model": "gpt-5.4"}}

    got = opt.optimize(spans, routing)
    proposal = got["implement-feature"]

    assert proposal["current_executor"] == "codex"
    assert proposal["current_model"] == "gpt-5.4"
    assert proposal["proposed_executor"] == "cursor"
    assert proposal["proposed_model"] == "cursor-auto"
    assert proposal["decision"] == "hold"
    assert proposal["reason"] == "executor_switch_unsupported"
