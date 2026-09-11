import importlib.util
import os

HERE = os.path.dirname(__file__)
_PATH = os.path.join(HERE, "..", "..", "legion-observability", "scripts", "legion-aggregate.py")
_spec = importlib.util.spec_from_file_location("legion_aggregate", _PATH)
agg = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(agg)


def test_percentile_edges():
    assert agg.percentile([], 50) == 0.0
    assert agg.percentile([10], 95) == 10.0
    assert agg.percentile([10, 20, 30, 40], 50) == 25.0


def test_aggregate_groups_success_and_cost():
    spans = [
        {"schema": "legion.span.v1", "executor": "codex", "model": "test-model-alpha", "status": "ok", "cost_usd": 0.1, "duration_ms": 100},
        {"schema": "legion.span.v1", "executor": "codex", "model": "test-model-alpha", "status": "failed", "cost_usd": 0.2, "duration_ms": 300},
        {"schema": "legion.span.v1", "executor": "anthropic", "model": "test-model-opus", "status": "ok", "cost_usd": 1.0, "duration_ms": 50},
        {"schema": "other"},  # ignored — wrong schema
    ]
    r = agg.aggregate(spans)
    assert r["groups"]["codex"]["count"] == 2
    assert r["groups"]["codex"]["success_rate"] == 0.5
    assert round(r["groups"]["codex"]["cost_usd"], 3) == 0.3
    assert r["total"]["count"] == 3
    assert round(r["total"]["cost_usd"], 3) == 1.3
    assert r["total"]["success_rate"] == round(2 / 3, 4)


def test_aggregate_tolerates_nan_and_missing_fields():
    spans = [
        {"schema": "legion.span.v1", "executor": "x", "status": "ok", "cost_usd": float("nan")},
        {"schema": "legion.span.v1", "executor": "x", "status": "ok"},  # no cost/duration/model
    ]
    r = agg.aggregate(spans)
    assert r["groups"]["x"]["cost_usd"] is None
    assert r["groups"]["x"]["cost_status"] == "unknown"
    assert r["groups"]["x"]["p50_ms"] == 0.0
    assert r["total"]["cost_usd"] is None


def test_aggregate_preserves_unknown_and_partial_metering():
    spans = [
        {"schema": "legion.span.v1", "executor": "deepseek", "status": "ok",
         "cost_usd": None, "cost_status": "unknown", "tokens": None,
         "usage_status": "unknown"},
        {"schema": "legion.span.v1", "executor": "deepseek", "status": "ok",
         "cost_usd": 0.25, "cost_status": "known", "tokens": {"input_tokens": 1},
         "usage_status": "known"},
    ]
    result = agg.aggregate(spans)
    group = result["groups"]["deepseek"]
    assert group["cost_usd"] is None
    assert group["cost_status"] == "partial"
    assert group["known_cost_usd"] == 0.25
    assert group["known_cost_runs"] == 1
    assert group["usage_status"] == "partial"
    assert group["known_usage_runs"] == 1


def test_aggregate_preserves_known_zero_as_measured():
    result = agg.aggregate([
        {"schema": "legion.span.v1", "executor": "local", "status": "ok",
         "cost_usd": 0, "cost_status": "known", "tokens": {}, "usage_status": "known"}
    ])
    group = result["groups"]["local"]
    assert group["cost_usd"] == 0
    assert group["cost_status"] == "known"
    assert group["known_cost_usd"] == 0
    assert group["known_cost_runs"] == 1
    assert group["usage_status"] == "known"
    assert group["known_usage_runs"] == 1


def test_aggregate_partial_span_preserves_known_subtotal_and_attempt_counts():
    result = agg.aggregate([
        {"schema": "legion.span.v1", "executor": "rollup", "status": "ok",
         "cost_usd": None, "cost_status": "partial", "known_cost_usd": 0.75,
         "known_cost_attempts": 3, "tokens": None, "usage_status": "partial",
         "known_usage": {"input_tokens": 10}, "known_usage_attempts": 2}
    ])
    group = result["groups"]["rollup"]
    assert group["cost_usd"] is None
    assert group["known_cost_usd"] == 0.75
    assert group["known_cost_runs"] == 3
    assert group["usage_status"] == "partial"
    assert group["known_usage_runs"] == 2


def test_load_tolerates_garbage_lines(tmp_path):
    p = tmp_path / "s.jsonl"
    p.write_text('{"schema":"legion.span.v1","executor":"a","model":"m","status":"ok"}\nGARBAGE\n\n')
    spans = agg.load([str(p)])
    assert len(spans) == 1


def test_aggregate_by_model_and_status():
    spans = [{"schema": "legion.span.v1", "executor": "codex", "model": "test-model-alpha", "status": "ok"}]
    assert "test-model-alpha" in agg.aggregate(spans, by="model")["groups"]
    assert "ok" in agg.aggregate(spans, by="status")["groups"]


def test_aggregate_by_archetype_surfaces_unclassified_delegations():
    spans = [
        {
            "schema": "legion.span.v1",
            "executor": "codex",
            "archetype": "implement-feature",
            "status": "ok",
            "cost_usd": 1.0,
        },
        {
            "schema": "legion.span.v1",
            "executor": "claude",
            "status": "ok",
            "cost_usd": 2.0,
        },
        {
            "schema": "legion.span.v1",
            "executor": "legion-bench",
            "status": "ok",
            "cost_usd": 0.0,
        },
    ]

    result = agg.aggregate(spans, by="archetype")

    assert set(result["groups"]) == {"implement-feature", "unclassified", "not_applicable"}
    assert result["groups"]["unclassified"]["cost_usd"] == 2.0
    assert result["classification"] == {
        "delegated_runs": 2,
        "classified_runs": 1,
        "unclassified_runs": 1,
        "classification_rate": 0.5,
        "unclassified_cost_usd": 2.0,
        "unclassified_cost_status": "known",
        "unclassified_known_cost_usd": 2.0,
        "unclassified_known_cost_runs": 1,
    }


def test_classification_covers_registered_executor_families_and_codex_modes():
    spans = [
        {
            "schema": "legion.span.v1",
            "executor": executor,
            "status": "ok",
            "cost_usd": 1.0,
        }
        for executor in ("codex-review", "codex-resume", "opencode")
    ]

    result = agg.aggregate(spans, by="archetype")

    assert result["groups"]["unclassified"]["count"] == 3
    assert result["classification"] == {
        "delegated_runs": 3,
        "classified_runs": 0,
        "unclassified_runs": 3,
        "classification_rate": 0.0,
        "unclassified_cost_usd": 3.0,
        "unclassified_cost_status": "known",
        "unclassified_known_cost_usd": 3.0,
        "unclassified_known_cost_runs": 3,
    }


def test_aggregate_folds_classification_into_grouping_pass(monkeypatch):
    def unexpected_second_pass(_spans):
        raise AssertionError("aggregate should not call classification_summary")

    monkeypatch.setattr(agg, "classification_summary", unexpected_second_pass)

    result = agg.aggregate([
        {
            "schema": "legion.span.v1",
            "executor": "codex",
            "archetype": "fix-bug",
            "status": "ok",
        },
        {
            "schema": "legion.span.v1",
            "executor": "claude",
            "status": "failed",
            "cost_usd": 2.0,
        },
    ])

    assert result["classification"]["classification_rate"] == 0.5


def test_unclassified_cost_preserves_partial_lower_bound():
    result = agg.aggregate([
        {"schema": "legion.span.v1", "executor": "codex", "status": "ok",
         "cost_usd": 0.75, "cost_status": "known"},
        {"schema": "legion.span.v1", "executor": "codex", "status": "failed",
         "cost_usd": None, "cost_status": "unknown"},
    ])

    classification = result["classification"]
    assert classification["unclassified_cost_usd"] is None
    assert classification["unclassified_cost_status"] == "partial"
    assert classification["unclassified_known_cost_usd"] == 0.75
    assert classification["unclassified_known_cost_runs"] == 1


def test_unclassified_cost_distinguishes_unknown_and_not_applicable():
    unknown = agg.classification_summary([
        {"schema": "legion.span.v1", "executor": "codex", "status": "failed",
         "cost_usd": None, "cost_status": "unknown"}
    ])
    assert unknown["unclassified_cost_usd"] is None
    assert unknown["unclassified_cost_status"] == "unknown"
    assert unknown["unclassified_known_cost_usd"] is None

    absent = agg.classification_summary([])
    assert absent["unclassified_cost_usd"] is None
    assert absent["unclassified_cost_status"] == "not_applicable"


def test_over_budget_usable_work_counts_as_success():
    spans = [
        {
            "schema": "legion.span.v1",
            "executor": "codex",
            "status": "over_budget",
            "cost_usd": 0.5,
        }
    ]

    result = agg.aggregate(spans)

    assert result["groups"]["codex"]["ok"] == 1
    assert result["groups"]["codex"]["success_rate"] == 1.0
    assert result["total"]["success_rate"] == 1.0


def test_aggregate_ignores_synthetic_opus_baselines():
    spans = [
        {"schema": "legion.span.v1", "executor": "codex", "model": "test-model-alpha", "status": "ok"},
        {
            "schema": "legion.span.v1",
            "executor": "opus-baseline",
            "model": "opus-baseline",
            "status": "ok",
            "artifacts": {"synthetic_opus_baseline": True},
        },
    ]
    r = agg.aggregate(spans)
    assert "opus-baseline" not in r["groups"]
    assert r["total"]["count"] == 1


def test_aggregate_ignores_rollup_only_spans():
    provider = {
        "schema": "legion.span.v1", "executor": "codex-review", "model": "review",
        "status": "ok", "cost_usd": 0.25, "duration_ms": 100,
        "artifacts": {"provider_attempt": True},
    }
    rollup = {
        **provider, "cost_usd": None, "duration_ms": 500,
        "artifacts": {"rollup_only": True},
    }

    result = agg.aggregate([provider, rollup])

    assert result["total"]["count"] == 1
    assert result["total"]["cost_usd"] == 0.25
    assert result["total"]["p50_ms"] == 100
    assert result["classification"]["delegated_runs"] == 1


def test_num_rejects_bool_nan_and_strings():
    assert agg._num(True) == 0          # bool is int 1 in Python — must be rejected
    assert agg._num(False) == 0
    assert agg._num(float("nan")) == 0
    assert agg._num(float("inf")) == 0
    assert agg._num("7") == 0
    assert agg._num(5) == 5
    assert agg._num(2.5) == 2.5


def test_contradictory_known_provenance_cannot_turn_unknown_into_free():
    result = agg.aggregate([
        {"schema": "legion.span.v1", "executor": "bad", "status": "ok",
         "cost_usd": None, "cost_status": "known", "tokens": None,
         "usage_status": "known"}
    ])
    assert result["groups"]["bad"]["cost_usd"] is None
    assert result["groups"]["bad"]["cost_status"] == "unknown"
    assert result["groups"]["bad"]["usage_status"] == "unknown"


def test_empty_input_is_safe():
    r = agg.aggregate([])
    assert r["total"]["count"] == 0
    assert r["total"]["cost_usd"] is None
    assert r["total"]["cost_status"] == "not_applicable"
    assert r["classification"] == {
        "delegated_runs": 0,
        "classified_runs": 0,
        "unclassified_runs": 0,
        "classification_rate": 0,
        "unclassified_cost_usd": None,
        "unclassified_cost_status": "not_applicable",
        "unclassified_known_cost_usd": None,
        "unclassified_known_cost_runs": 0,
    }
