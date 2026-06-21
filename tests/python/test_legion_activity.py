import importlib.util
import json
import os


HERE = os.path.dirname(__file__)
PATH = os.path.join(
    HERE, "..", "..", "legion-observability", "scripts", "legion-activity.py"
)
SPEC = importlib.util.spec_from_file_location("legion_activity", PATH)
activity = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(activity)


def _write_json(path, payload):
    path.write_text(json.dumps(payload), encoding="utf-8")


def _write_stream(path):
    lines = [
        "garbage",
        json.dumps(
            {
                "type": "turn.completed",
                "usage": {
                    "input_tokens": 1000,
                    "cached_input_tokens": 200,
                    "output_tokens": 50,
                    "reasoning_output_tokens": 10,
                },
            }
        ),
        json.dumps(
            {
                "type": "item.completed",
                "item": {
                    "id": "item-1",
                    "type": "command_execution",
                    "command": ["rg", "activity"],
                },
            }
        ),
        json.dumps(
            {
                "type": "item.completed",
                "payload": {
                    "type": "file_change",
                    "changes": [
                        {"path": "src/app.py"},
                        {"path": "README.md"},
                        {"path": "Makefile"},
                    ],
                },
            }
        ),
        json.dumps(
            {
                "type": "item.completed",
                "item": {
                    "id": "item-3",
                    "type": "mcp_tool_call",
                    "server": "fs",
                    "tool": "read_file",
                },
            }
        ),
        json.dumps(
            {
                "type": "turn.completed",
                "usage": {
                    "input_tokens": 500,
                    "cached_input_tokens": 100,
                    "output_tokens": 25,
                    "reasoning_output_tokens": 5,
                },
            }
        ),
    ]
    path.write_text("\n".join(lines) + "\n", encoding="utf-8")


def _costs_payload():
    return {
        "models": [
            {
                "match": "gpt-5.4",
                "input": 2.0,
                "output": 10.0,
                "cache_read": 0.5,
                "cache_write": 0.0,
            }
        ],
        "default": {
            "input": 1.0,
            "output": 4.0,
            "cache_read": 0.2,
            "cache_write": 0.0,
        },
    }


def _usage():
    return {
        "input_tokens": 1500,
        "cached_input_tokens": 300,
        "output_tokens": 75,
        "reasoning_output_tokens": 15,
    }


def _resume_usage():
    return {
        "input_tokens": 250,
        "cached_input_tokens": 50,
        "output_tokens": 10,
        "reasoning_output_tokens": 2,
    }


def test_cost_for_bills_cached_tokens_at_cache_read_and_falls_back_to_default(tmp_path):
    costs_path = tmp_path / "costs.json"
    _write_json(costs_path, _costs_payload())
    costs = activity.load_costs(str(costs_path))

    known = activity.cost_for("GPT-5.4", _usage(), costs)
    unknown = activity.cost_for("mystery-model", _usage(), costs)

    assert known == 0.00345
    assert unknown == 0.00162


def test_parse_stream_sums_usage_and_collects_tools_files_and_items(tmp_path):
    stream_path = tmp_path / "stream.jsonl"
    _write_stream(stream_path)

    parsed = activity.parse_stream(str(stream_path))
    tools = {tool["name"]: tool["count"] for tool in parsed["tools"]}

    assert parsed["usage"] == _usage()
    assert tools == {"shell": 1, "file edit": 1, "mcp:fs/read_file": 1}
    assert parsed["files"] == ["Makefile", "README.md", "src/app.py"]
    assert parsed["items"] == 3
    assert parsed["summary"]
    assert "3 items" in parsed["summary"]


def test_run_cost_uses_stream_and_resume_stream_usage_not_spans(tmp_path):
    costs_path = tmp_path / "costs.json"
    run_dir = tmp_path / "runs" / "run-1"
    run_dir.mkdir(parents=True)
    _write_json(costs_path, _costs_payload())
    _write_stream(run_dir / "stream.jsonl")
    (run_dir / "resume-stream.jsonl").write_text(
        json.dumps({"type": "turn.completed", "usage": _resume_usage()}) + "\n",
        encoding="utf-8",
    )

    costs = activity.load_costs(str(costs_path))
    cost = activity.run_cost(str(run_dir), "gpt-5.4", costs)

    assert cost == 0.003995
    assert cost > 0.0


def test_enrich_run_falls_back_to_span_cost_when_stream_is_gone():
    # The stream (repo .legion/runs) is ephemeral and gets cleaned; the span
    # (~/.claude/logs/legion/spans) is durable. When there's no stream, cost must
    # come from the span so a finished run still shows its real cost (the $0 fix).
    rec = {"run_id": "gone", "model": "gpt-5.4", "lifecycle": {"phase": "ok"}}
    enriched = activity.enrich_run(rec, "", _costs_payload(), span_costs={"gone": 0.4242})
    assert enriched["cost_usd"] == 0.4242  # from the durable span, stream absent


def test_group_by_session_merges_a_fanouts_agents_across_their_worktrees():
    # A session (trace_id) = one fan-out that spawned N agents in N ephemeral
    # worktrees. Grouping by trace_id collects them; grouping by worktree would be 1:1.
    grouped = activity.group_by_session(
        [
            {
                "run_id": "run-1",
                "trace_id": "fanout-X",
                "repo_root": "/repo",
                "worktree_dir": "/repo/.legion/worktrees/a",
                "phase": "running",
                "cost_usd": 1.25,
                "activity": {
                    "tools": [
                        {"name": "shell", "count": 2},
                        {"name": "file edit", "count": 1},
                    ]
                },
            },
            {
                "run_id": "run-2",
                "trace_id": "fanout-X",
                "repo_root": "/repo",
                "worktree_dir": "/repo/.legion/worktrees/b",  # different worktree, same session
                "phase": "ok",
                "cost_usd": 0.75,
                "activity": {
                    "tools": [
                        {"name": "shell", "count": 1},
                        {"name": "mcp:fs/read_file", "count": 3},
                    ]
                },
            },
            {
                "run_id": "run-3",
                "trace_id": "",  # standalone (no session)
                "repo_root": "/repo",
                "worktree_dir": "/repo/.legion/worktrees/c",
                "phase": "failed",
                "cost_usd": 0.1,
                "activity": {"tools": []},
            },
        ]
    )

    first = grouped[0]
    tool_counts = {tool["name"]: tool["count"] for tool in first["tools"]}

    assert first["session"] == "fanout-X"
    assert first["cost_usd"] == 2.0
    assert first["run_count"] == 2
    assert first["runs"] == ["run-1", "run-2"]
    assert first["worktrees"] == [
        "/repo/.legion/worktrees/a",
        "/repo/.legion/worktrees/b",
    ]  # both worktrees of the session, grouped under it
    assert first["statuses"] == {"running": 1, "ok": 1}
    assert tool_counts == {"mcp:fs/read_file": 3, "shell": 3, "file edit": 1}
    # the standalone run falls back to its own run_id as the session key
    standalone = [g for g in grouped if g["session"] == "run-3"][0]
    assert standalone["runs"] == ["run-3"]


def test_build_activity_uses_registry_records_and_run_root(tmp_path):
    registry_dir = tmp_path / "registry"
    runs_root = tmp_path / "runs"
    run_dir = runs_root / "run-1"
    costs_path = tmp_path / "costs.json"

    registry_dir.mkdir()
    run_dir.mkdir(parents=True)
    _write_json(costs_path, _costs_payload())
    _write_json(
        registry_dir / "run-1.json",
        {
            "schema": "legion.run-state.v1",
            "run_id": "run-1",
            "model": "gpt-5.4",
            "archetype": "implement-feature",
            "worktree_dir": "/repo/.legion/worktrees/a",
            "branch": "main",
            "repo_root": "/repo",
            "lifecycle": {"phase": "ok"},
        },
    )
    _write_stream(run_dir / "stream.jsonl")

    built = activity.build_activity(
        str(registry_dir),
        str(runs_root),
        str(costs_path),
    )

    assert built["totals"]["cost_usd"] == 0.00345
    assert built["totals"]["runs"] == 1
    assert built["totals"]["tools"] == {
        "file edit": 1,
        "mcp:fs/read_file": 1,
        "shell": 1,
    }
    assert built["sessions"][0]["worktrees"] == ["/repo/.legion/worktrees/a"]
    assert built["runs"][0]["activity"]["summary"] == "3 items · 3 tools · 3 files"
