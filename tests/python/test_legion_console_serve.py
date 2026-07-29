"""Smoke test for the Console dev server: it loads the indexer + serves a snapshot
shape. (The HTTP/SSE plumbing is stdlib; we test the data path, not the socket.)"""
import importlib.util
import json
import os

_HERE = os.path.dirname(os.path.abspath(__file__))
_SERVE = os.path.join(
    _HERE, "..", "..", "legion-observability", "scripts", "legion-console-serve.py")


def _load():
    spec = importlib.util.spec_from_file_location("legion_console_serve", _SERVE)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


def test_server_imports_indexer_and_html_exists():
    srv = _load()
    assert hasattr(srv.IDX, "build_snapshot")
    assert os.path.isfile(srv.HTML_PATH), srv.HTML_PATH


def test_snapshot_path_returns_valid_shape(tmp_path):
    srv = _load()
    reg = tmp_path / "registry"
    spans = tmp_path / "spans"
    reg.mkdir()
    spans.mkdir()
    (reg / "r.json").write_text(json.dumps({
        "schema": "legion.run-state.v1", "run_id": "r", "model": "test-model-alpha",
        "run_dir": str(tmp_path / "runs" / "r"), "worktree_dir": str(tmp_path / "wt"),
        "process": {"pid": 0, "pgid": 0, "started_at": "2026-06-15T12:00:00Z"},
        "lifecycle": {"phase": "ok", "started_at": "2026-06-15T12:00:00Z",
                      "updated_at": "2026-06-15T12:01:00Z"},
    }))
    srv.CFG.update(registry=str(reg), spans=str(spans))
    snap = srv.snapshot()
    assert "runs" in snap and "aggregates" in snap and "traces" in snap
    assert snap["aggregates"]["by_model"]["test-model-alpha"]["runs"] == 1
