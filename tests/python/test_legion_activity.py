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
                "match": "test-model-alpha",
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

    known = activity.cost_for("test-model-alpha", _usage(), costs)
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
    cost = activity.run_cost(str(run_dir), "test-model-alpha", costs)

    assert cost == 0.003995
    assert cost > 0.0


def test_enrich_run_falls_back_to_span_cost_when_stream_is_gone():
    # The stream (repo .legion/runs) is ephemeral and gets cleaned; the span
    # (~/.claude/logs/legion/spans) is durable. When there's no stream, cost must
    # come from the span so a finished run still shows its real cost (the $0 fix).
    rec = {"run_id": "gone", "model": "test-model-alpha", "lifecycle": {"phase": "ok"}}
    enriched = activity.enrich_run(rec, "", _costs_payload(), span_costs={"gone": 0.4242})
    assert enriched["cost_usd"] == 0.4242  # from the durable span, stream absent


def test_activity_preserves_partial_durable_cost_as_a_lower_bound(tmp_path):
    spans = tmp_path / "spans"
    spans.mkdir()
    (spans / "2026-09-11.jsonl").write_text("\n".join([
        json.dumps({"schema": "legion.span.v1", "run_id": "mixed",
                    "cost_usd": 0, "cost_status": "known"}),
        json.dumps({"schema": "legion.span.v1", "run_id": "mixed",
                    "cost_usd": None, "cost_status": "unknown"}),
    ]) + "\n")
    summaries = activity.load_span_costs(str(spans))
    assert summaries["mixed"] == {
        "cost_usd": None,
        "cost_status": "partial",
        "known_cost_usd": 0,
        "known_cost_attempts": 1,
        "attempt_count": 2,
    }
    rec = {"run_id": "mixed", "model": "test-model-alpha", "lifecycle": {"phase": "ok"}}
    enriched = activity.enrich_run(rec, "", _costs_payload(), span_costs=summaries)
    assert enriched["cost_usd"] is None
    assert enriched["cost_status"] == "partial"
    assert enriched["known_cost_usd"] == 0
    assert activity._format_cost(
        enriched["cost_usd"], enriched["cost_status"], enriched["known_cost_usd"]
    ) == ">=0.000000"
    assert activity._format_cost(None, "unknown") == "unknown"


def test_completed_multi_attempt_activity_prefers_durable_reconciliation(tmp_path):
    run_dir = tmp_path / "runs" / "retried"
    run_dir.mkdir(parents=True)
    _write_stream(run_dir / "stream.jsonl")
    durable = {
        "retried": {
            "cost_usd": 1.25,
            "cost_status": "known",
            "known_cost_usd": 1.25,
            "known_cost_attempts": 2,
            "attempt_count": 2,
        }
    }

    completed = activity.enrich_run(
        {"run_id": "retried", "model": "test-model-alpha", "lifecycle": {"phase": "ok"}},
        str(run_dir),
        _costs_payload(),
        span_costs=durable,
    )
    running = activity.enrich_run(
        {"run_id": "retried", "model": "test-model-alpha", "lifecycle": {"phase": "running"}},
        str(run_dir),
        _costs_payload(),
        span_costs=durable,
    )

    assert completed["cost_usd"] == 1.25
    assert completed["known_cost_attempts"] == 2
    assert "attempt_count" not in completed
    assert completed["activity"]["items"] == 3
    assert running["cost_usd"] == 0.00345
    assert running["known_cost_attempts"] == 1


def test_completed_all_unknown_retries_still_prefer_durable_unknown(tmp_path):
    spans = tmp_path / "spans"
    spans.mkdir()
    (spans / "2026-09-11.jsonl").write_text("\n".join([
        json.dumps({"schema": "legion.span.v1", "run_id": "retried",
                    "cost_usd": None, "cost_status": "unknown"}),
        json.dumps({"schema": "legion.span.v1", "run_id": "retried",
                    "cost_usd": None, "cost_status": "unknown"}),
    ]) + "\n")
    run_dir = tmp_path / "runs" / "retried"
    run_dir.mkdir(parents=True)
    _write_stream(run_dir / "stream.jsonl")

    summaries = activity.load_span_costs(str(spans))
    assert summaries["retried"]["attempt_count"] == 2
    enriched = activity.enrich_run(
        {"run_id": "retried", "model": "test-model-alpha", "lifecycle": {"phase": "failed"}},
        str(run_dir),
        _costs_payload(),
        span_costs=summaries,
    )

    assert enriched["cost_usd"] is None
    assert enriched["cost_status"] == "unknown"


def test_completed_single_attempt_prefers_durable_provenance(tmp_path):
    run_dir = tmp_path / "runs" / "single"
    run_dir.mkdir(parents=True)
    _write_stream(run_dir / "stream.jsonl")
    durable = {
        "single": {
            "cost_usd": None,
            "cost_status": "unknown",
            "known_cost_usd": None,
            "known_cost_attempts": 0,
            "attempt_count": 1,
        }
    }

    enriched = activity.enrich_run(
        {"run_id": "single", "model": "test-model-alpha", "lifecycle": {"phase": "ok"}},
        str(run_dir),
        _costs_payload(),
        span_costs=durable,
    )

    assert enriched["cost_usd"] is None
    assert enriched["cost_status"] == "unknown"
    assert enriched["activity"]["items"] == 3


def test_running_stream_cost_stays_unknown_without_usage_evidence(tmp_path):
    run_dir = tmp_path / "runs" / "no-usage"
    run_dir.mkdir(parents=True)
    (run_dir / "stream.jsonl").write_text(
        json.dumps({
            "type": "item.completed",
            "item": {"type": "agent_message", "text": "still running"},
        }) + "\n",
        encoding="utf-8",
    )

    enriched = activity.enrich_run(
        {"run_id": "no-usage", "model": "test-model-alpha", "lifecycle": {"phase": "running"}},
        str(run_dir),
        activity._normalize_costs(_costs_payload()),
    )

    assert enriched["cost_usd"] is None
    assert enriched["cost_status"] == "unknown"
    assert enriched["known_cost_attempts"] == 0


def test_running_stream_cost_stays_unknown_without_pricing_evidence(tmp_path):
    run_dir = tmp_path / "runs" / "no-pricing"
    run_dir.mkdir(parents=True)
    _write_stream(run_dir / "stream.jsonl")

    enriched = activity.enrich_run(
        {"run_id": "no-pricing", "model": "unpriced", "lifecycle": {"phase": "running"}},
        str(run_dir),
        activity.load_costs(str(tmp_path / "missing-costs.json")),
    )

    assert enriched["cost_usd"] is None
    assert enriched["cost_status"] == "unknown"
    assert enriched["known_cost_attempts"] == 0


def test_running_stream_accepts_observed_usage_and_explicit_zero_pricing(tmp_path):
    run_dir = tmp_path / "runs" / "zero-priced"
    run_dir.mkdir(parents=True)
    _write_stream(run_dir / "stream.jsonl")
    costs = _costs_payload()
    costs["default"] = {"input": 0, "output": 0, "cache_read": 0, "cache_write": 0}

    enriched = activity.enrich_run(
        {"run_id": "zero-priced", "model": "unpriced", "lifecycle": {"phase": "running"}},
        str(run_dir),
        activity._normalize_costs(costs),
    )

    assert enriched["cost_usd"] == 0
    assert enriched["cost_status"] == "known"


def test_refused_no_launch_run_is_terminal_and_prefers_durable_provenance(tmp_path):
    run_dir = tmp_path / "runs" / "refused"
    run_dir.mkdir(parents=True)
    _write_stream(run_dir / "stream.jsonl")
    durable = {
        "refused": {
            "cost_usd": None,
            "cost_status": "not_applicable",
            "known_cost_usd": None,
            "known_cost_attempts": 0,
            "attempt_count": 1,
        }
    }

    enriched = activity.enrich_run(
        {"run_id": "refused", "model": "test-model-alpha", "lifecycle": {"phase": "refused"}},
        str(run_dir),
        _costs_payload(),
        span_costs=durable,
    )

    assert enriched["cost_usd"] is None
    assert enriched["cost_status"] == "not_applicable"


def test_activity_cost_loader_excludes_rollup_only_span(tmp_path):
    spans = tmp_path / "spans"
    spans.mkdir()
    provider = {
        "schema": "legion.span.v1", "run_id": "single", "cost_usd": 0.5,
        "cost_status": "known", "artifacts": {"provider_attempt": True},
    }
    rollup = {
        **provider, "cost_usd": None, "cost_status": "not_applicable",
        "artifacts": {"rollup_only": True},
    }
    (spans / "2026-09-11.jsonl").write_text(
        "\n".join(json.dumps(span) for span in (provider, rollup)) + "\n",
        encoding="utf-8",
    )

    assert activity.load_span_costs(str(spans))["single"] == {
        "cost_usd": 0.5,
        "cost_status": "known",
        "known_cost_usd": 0.5,
        "known_cost_attempts": 1,
        "attempt_count": 1,
    }


def test_activity_known_plus_not_applicable_cost_is_partial(tmp_path):
    spans = tmp_path / "spans"
    spans.mkdir()
    payloads = [
        {"schema": "legion.span.v1", "run_id": "mixed-applicability",
         "cost_usd": 0.75, "cost_status": "known"},
        {"schema": "legion.span.v1", "run_id": "mixed-applicability",
         "cost_usd": None, "cost_status": "not_applicable"},
    ]
    (spans / "2026-09-11.jsonl").write_text(
        "\n".join(json.dumps(span) for span in payloads) + "\n",
        encoding="utf-8",
    )

    assert activity.load_span_costs(str(spans))["mixed-applicability"] == {
        "cost_usd": None,
        "cost_status": "partial",
        "known_cost_usd": 0.75,
        "known_cost_attempts": 1,
        "attempt_count": 1,
    }


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
            "model": "test-model-alpha",
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
