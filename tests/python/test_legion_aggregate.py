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
        {"schema": "legion.span.v1", "executor": "codex", "model": "gpt-5.4", "status": "ok", "cost_usd": 0.1, "duration_ms": 100},
        {"schema": "legion.span.v1", "executor": "codex", "model": "gpt-5.4", "status": "failed", "cost_usd": 0.2, "duration_ms": 300},
        {"schema": "legion.span.v1", "executor": "anthropic", "model": "claude-opus-4-8", "status": "ok", "cost_usd": 1.0, "duration_ms": 50},
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
    assert r["groups"]["x"]["cost_usd"] == 0          # NaN coerced to 0
    assert r["groups"]["x"]["p50_ms"] == 0.0
    assert r["total"]["cost_usd"] == 0


def test_load_tolerates_garbage_lines(tmp_path):
    p = tmp_path / "s.jsonl"
    p.write_text('{"schema":"legion.span.v1","executor":"a","model":"m","status":"ok"}\nGARBAGE\n\n')
    spans = agg.load([str(p)])
    assert len(spans) == 1


def test_aggregate_by_model_and_status():
    spans = [{"schema": "legion.span.v1", "executor": "codex", "model": "gpt-5.4", "status": "ok"}]
    assert "gpt-5.4" in agg.aggregate(spans, by="model")["groups"]
    assert "ok" in agg.aggregate(spans, by="status")["groups"]


def test_aggregate_ignores_synthetic_opus_baselines():
    spans = [
        {"schema": "legion.span.v1", "executor": "codex", "model": "gpt-5.4", "status": "ok"},
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


def test_num_rejects_bool_nan_and_strings():
    assert agg._num(True) == 0          # bool is int 1 in Python — must be rejected
    assert agg._num(False) == 0
    assert agg._num(float("nan")) == 0
    assert agg._num("7") == 0
    assert agg._num(5) == 5
    assert agg._num(2.5) == 2.5


def test_empty_input_is_safe():
    r = agg.aggregate([])
    assert r["total"] == {"count": 0, "ok": 0, "cost_usd": 0, "success_rate": 0}
