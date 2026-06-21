import importlib.util
import os

HERE = os.path.dirname(__file__)
_PATH = os.path.join(HERE, "..", "..", "legion-observability", "scripts", "legion-share.py")
_spec = importlib.util.spec_from_file_location("legion_share", _PATH)
ls = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(ls)


def _span(executor, model, out):
    return {"schema": "legion.span.v1", "executor": executor, "model": model,
            "status": "ok", "tokens": {"output_tokens": out}}


def test_is_codex():
    assert ls.is_codex("codex")
    assert ls.is_codex("codex-review")
    assert ls.is_codex("codex-resume")
    assert not ls.is_codex("opus")
    assert not ls.is_codex("")
    assert not ls.is_codex(None)


def test_compute_share_runs_and_tokens():
    spans = [_span("codex", "gpt-5.4", 300), _span("opus", "opus", 500), _span("opus", "opus", 400)]
    c = ls.compute(spans)
    assert c["total_runs"] == 3 and c["codex_runs"] == 1 and c["opus_runs"] == 2
    assert c["codex_share_runs"] == round(1 / 3, 4)
    assert c["codex_share_tokens"] == round(300 / 1200, 4)
    assert c["by_model"]["opus"] == 2 and c["by_model"]["gpt-5.4"] == 1


def test_compute_empty_is_safe():
    c = ls.compute([])
    assert c["total_runs"] == 0 and c["codex_share_runs"] == 0.0 and c["codex_share_tokens"] == 0.0


def test_target_default_and_env(monkeypatch):
    monkeypatch.delenv("LEGION_TARGET_CODEX_SHARE", raising=False)
    # explicit wins
    assert ls.target_share(0.7, routing="/nope") == 0.7
    # env wins over default
    monkeypatch.setenv("LEGION_TARGET_CODEX_SHARE", "0.6")
    assert ls.target_share(None, routing="/nope") == 0.6
    # falls back to 0.5 with no env/routing
    monkeypatch.delenv("LEGION_TARGET_CODEX_SHARE", raising=False)
    assert ls.target_share(None, routing="/does/not/exist") == 0.5


def test_target_reads_routing_toml():
    routing = os.path.join(HERE, "..", "..", "legion-router", "config", "routing.toml")
    # routing.toml ships codex_share = 0.5
    assert ls.target_share(None, routing=routing) == 0.5


def test_failed_runs_excluded_from_share():
    spans = [
        _span("codex", "gpt-5.4", 100),
        {"schema": "legion.span.v1", "executor": "codex", "model": "gpt-5.4", "status": "failed", "tokens": {"output_tokens": 9}},
        _span("opus", "opus", 100),
    ]
    c = ls.compute(spans)
    assert c["total_runs"] == 2          # failed one not counted
    assert c["codex_runs"] == 1 and c["opus_runs"] == 1
    assert c["failed_runs"] == 1
    assert c["codex_share_runs"] == 0.5


def test_reasoning_tokens_count_toward_codex():
    spans = [
        {"schema": "legion.span.v1", "executor": "codex", "model": "gpt-5.5", "status": "ok",
         "tokens": {"output_tokens": 100, "reasoning_output_tokens": 300}},
        _span("opus", "opus", 100),
    ]
    c = ls.compute(spans)
    # codex generated 400 (100 out + 300 reasoning), opus 100 -> 0.8
    assert c["codex_share_tokens"] == round(400 / 500, 4)


def test_target_is_clamped():
    assert ls.target_share(5.0, routing="/nope") == 1.0
    assert ls.target_share(-1.0, routing="/nope") == 0.0


def test_recommend_next_converges_to_target():
    assert ls.recommend_next(0.0, 0, 0.5) == "codex"     # no history -> start delegating
    assert ls.recommend_next(0.33, 3, 0.5) == "codex"    # under target -> codex
    assert ls.recommend_next(0.60, 5, 0.5) == "opus"     # at/over target -> opus
    assert ls.recommend_next(0.50, 4, 0.5) == "opus"     # exactly met -> opus
