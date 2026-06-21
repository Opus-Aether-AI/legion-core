import importlib.util
import json
import os


HERE = os.path.dirname(__file__)
PATH = os.path.join(
    HERE, "..", "..", "legion-observability", "scripts", "legion-console-index.py"
)
SPEC = importlib.util.spec_from_file_location("legion_console_index", PATH)
indexer = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(indexer)


def _record(
    run_id,
    *,
    trace_id="trace-1",
    parent_id=None,
    phase="running",
    started_at="2026-06-15T10:00:00Z",
    updated_at="2026-06-15T10:05:00Z",
    model="gpt-5.4",
    kind="task",
    repo_root="/repo",
    run_dir="/run",
    worktree_dir="/worktree",
    pid=101,
    pgid=201,
):
    return {
        "schema": "legion.run-state.v1",
        "run_id": run_id,
        "trace_id": trace_id,
        "parent_id": parent_id,
        "kind": kind,
        "state_version": 1,
        "repo_root": repo_root,
        "run_dir": run_dir,
        "worktree_dir": worktree_dir,
        "branch": "main",
        "model": model,
        "sandbox": "workspace-write",
        "reasoning_effort": "high",
        "base_ref": "origin/main",
        "process": {
            "pid": pid,
            "pgid": pgid,
            "started_at": started_at,
            "host": "localhost",
        },
        "lifecycle": {
            "phase": phase,
            "started_at": started_at,
            "updated_at": updated_at,
        },
    }


def _span(
    run_id,
    *,
    ts="2026-06-15T10:10:00Z",
    trace_id="trace-1",
    parent_id=None,
    status="ok",
    cost_usd=0.0,
    model="gpt-5.4",
    tokens=None,
):
    return {
        "schema": "legion.span.v1",
        "ts": ts,
        "run_id": run_id,
        "trace_id": trace_id,
        "parent_id": parent_id,
        "executor": "codex",
        "model": model,
        "task": "task",
        "status": status,
        "duration_ms": 100,
        "cost_usd": cost_usd,
        "tokens": tokens
        or {
            "input_tokens": 0,
            "cached_input_tokens": 0,
            "output_tokens": 0,
            "reasoning_output_tokens": 0,
        },
        "artifacts": [],
    }


def _write_registry(registry_dir, *records):
    registry_dir.mkdir(parents=True, exist_ok=True)
    for record in records:
        (registry_dir / f"{record['run_id']}.json").write_text(json.dumps(record))


def _write_spans(spans_dir, *spans):
    spans_dir.mkdir(parents=True, exist_ok=True)
    lines = "\n".join(json.dumps(span) for span in spans) + "\n"
    (spans_dir / "2026-06-15.jsonl").write_text(lines)


def test_derive_status_queued_preallocated_slice():
    # A fanout-preallocated slice: phase=queued, no span, dead pid (0) -> "queued".
    q = _record("q", phase="queued", started_at="", pid=0)
    assert indexer.derive_status(
        q, None, alive=False, worktree_exists=False, diff_exists=False
    ) == "queued"


def test_awaiting_human_requires_a_live_worktree():
    # ok + diff but the ephemeral worktree was cleaned -> done (not a forever-pending
    # action); ok + diff + worktree still there -> awaiting_human (actionable).
    rec = _record("r", phase="ok")
    span = {"run_id": "r", "status": "ok"}
    gone = indexer.derive_status(rec, span, alive=False, worktree_exists=False, diff_exists=True)
    live = indexer.derive_status(rec, span, alive=False, worktree_exists=True, diff_exists=True)
    assert gone == "done"
    assert live == "awaiting_human"


def test_derive_status_state_machine():
    running = _record("run-a", phase="running")
    ok_record = _record("run-b", phase="ok")
    failed_record = _record("run-c", phase="failed")

    assert indexer.derive_status(
        running, None, alive=True, worktree_exists=True, diff_exists=False
    ) == "running"
    assert indexer.derive_status(
        running, None, alive=False, worktree_exists=True, diff_exists=False
    ) == "orphaned"
    assert indexer.derive_status(
        running,
        _span("run-a", status="ok"),
        alive=False,
        worktree_exists=True,
        diff_exists=True,
    ) == "awaiting_human"
    assert indexer.derive_status(
        ok_record,
        _span("run-b", status="ok"),
        alive=False,
        worktree_exists=True,
        diff_exists=True,
    ) == "awaiting_human"
    assert indexer.derive_status(
        ok_record,
        _span("run-b", status="ok"),
        alive=False,
        worktree_exists=True,
        diff_exists=False,
    ) == "done"
    assert indexer.derive_status(
        failed_record,
        _span("run-c", status="failed"),
        alive=False,
        worktree_exists=True,
        diff_exists=False,
    ) == "failed"


def test_load_spans_latest_ts_wins_and_sums_cost_and_tokens(tmp_path):
    spans_dir = tmp_path / "spans"
    _write_spans(
        spans_dir,
        _span(
            "run-1",
            ts="2026-06-15T10:00:00Z",
            status="running",
            cost_usd=0.25,
            tokens={
                "input_tokens": 10,
                "cached_input_tokens": 1,
                "output_tokens": 2,
                "reasoning_output_tokens": 3,
            },
        ),
        _span(
            "run-1",
            ts="2026-06-15T10:05:00Z",
            status="ok",
            cost_usd=0.75,
            tokens={
                "input_tokens": 20,
                "cached_input_tokens": 2,
                "output_tokens": 4,
                "reasoning_output_tokens": 6,
            },
        ),
    )

    spans = indexer.load_spans(str(spans_dir))

    assert spans["run-1"]["status"] == "ok"
    assert spans["run-1"]["cost_usd"] == 1.0
    assert spans["run-1"]["tokens"] == {
        "input_tokens": 30,
        "cached_input_tokens": 3,
        "output_tokens": 6,
        "reasoning_output_tokens": 9,
    }


def test_build_snapshot_aggregates_traces_and_sorting(tmp_path):
    registry_dir = tmp_path / "registry"
    spans_dir = tmp_path / "spans"

    run_root = tmp_path / "runs"
    worktrees = tmp_path / "worktrees"
    run1_dir = run_root / "run-1"
    run2_dir = run_root / "run-2"
    run3_dir = run_root / "run-3"
    wt1 = worktrees / "wt-1"
    wt2 = worktrees / "wt-2"
    wt3 = worktrees / "wt-3"
    for path in (run1_dir, run2_dir, run3_dir, wt1, wt2, wt3):
        path.mkdir(parents=True, exist_ok=True)
    (run2_dir / "diff.patch").write_text("diff")

    rec1 = _record(
        "run-1",
        trace_id="trace-1",
        parent_id=None,
        phase="ok",
        started_at="2026-06-15T09:00:00Z",
        updated_at="2026-06-15T09:30:00Z",
        model="gpt-5.4",
        run_dir=str(run1_dir),
        worktree_dir=str(wt1),
        pid=111,
    )
    rec2 = _record(
        "run-2",
        trace_id="trace-1",
        parent_id="run-1",
        phase="ok",
        started_at="2026-06-15T11:00:00Z",
        updated_at="2026-06-15T11:20:00Z",
        model="gpt-5.4-mini",
        run_dir=str(run2_dir),
        worktree_dir=str(wt2),
        pid=112,
    )
    rec3 = _record(
        "run-3",
        trace_id="trace-2",
        parent_id=None,
        phase="failed",
        started_at="2026-06-15T10:00:00Z",
        updated_at="2026-06-15T10:10:00Z",
        model="claude-opus-4.8",
        run_dir=str(run3_dir),
        worktree_dir=str(wt3),
        pid=113,
    )
    _write_registry(registry_dir, rec1, rec2, rec3)
    _write_spans(
        spans_dir,
        _span("run-1", trace_id="trace-1", parent_id=None, status="ok", cost_usd=1.5),
        _span(
            "run-2",
            trace_id="trace-1",
            parent_id="run-1",
            status="ok",
            cost_usd=2.0,
        ),
        _span(
            "run-3",
            trace_id="trace-2",
            parent_id=None,
            status="failed",
            cost_usd=3.0,
            model="claude-opus-4.8",
        ),
    )

    snapshot = indexer.build_snapshot(
        str(registry_dir),
        str(spans_dir),
        now="2026-06-15T12:00:00Z",
    )

    assert [run["run_id"] for run in snapshot["runs"]] == ["run-2", "run-3", "run-1"]
    assert snapshot["aggregates"]["by_status"] == {"awaiting_human": 1, "failed": 1, "done": 1}
    # by_model carries COST (+ run count), not just a count (the "$16 vs $1" bug).
    assert snapshot["aggregates"]["by_model"] == {
        "gpt-5.4": {"runs": 1, "cost_usd": 1.5},
        "gpt-5.4-mini": {"runs": 1, "cost_usd": 2.0},
        "claude-opus-4.8": {"runs": 1, "cost_usd": 3.0},
    }
    assert snapshot["aggregates"]["total_cost_usd"] == 6.5
    assert snapshot["aggregates"]["running"] == 0
    assert snapshot["aggregates"]["awaiting_human"] == 1

    # elapsed is FROZEN at the terminal write (updated_at - started_at) for finished
    # runs — not (now - started_at), which would tick forever. now=12:00.
    by_id = {run["run_id"]: run for run in snapshot["runs"]}
    assert by_id["run-1"]["elapsed_s"] == 1800   # 09:00 -> 09:30, not 3h to noon
    assert by_id["run-2"]["elapsed_s"] == 1200   # 11:00 -> 11:20
    assert by_id["run-3"]["elapsed_s"] == 600    # 10:00 -> 10:10

    assert [trace["trace_id"] for trace in snapshot["traces"]] == ["trace-1", "trace-2"]
    trace1 = snapshot["traces"][0]
    assert trace1["runs"] == ["run-2", "run-1"]
    assert trace1["cost_usd"] == 3.5
    assert [root["run_id"] for root in trace1["roots"]] == ["run-1"]
    assert [child["run_id"] for child in trace1["roots"][0]["children"]] == ["run-2"]


def test_pid_alive_rejects_non_positive_pids():
    assert indexer.pid_alive(0) is False
    assert indexer.pid_alive(-7) is False


def test_running_elapsed_ticks_to_now_not_frozen():
    # A live run (pid = this test process) ticks to `now`, NOT frozen at updated_at.
    rec = _record(
        "live",
        phase="running",
        started_at="2026-06-15T11:59:00Z",
        updated_at="2026-06-15T11:59:30Z",
        pid=os.getpid(),
    )
    run = indexer._build_run(rec, None, now="2026-06-15T12:00:00Z")
    assert run["status"] == "running"
    assert run["elapsed_s"] == 60  # now - started (60s), not frozen at updated (30s)
