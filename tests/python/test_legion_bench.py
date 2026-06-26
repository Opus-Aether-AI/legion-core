import importlib.util
import json
import os


HERE = os.path.dirname(__file__)
PATH = os.path.join(
    HERE, "..", "..", "legion-observability", "scripts", "legion-bench.py"
)
SPEC = importlib.util.spec_from_file_location("legion_bench", PATH)
bench = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(bench)


def test_eval_case_scores_tiny_marketplace(tmp_path):
    repo = tmp_path / "repo"
    marketplace = repo / ".claude-plugin"
    marketplace.mkdir(parents=True)
    (marketplace / "marketplace.json").write_text(
        json.dumps(
            {
                "plugins": [
                    {
                        "name": "obs",
                        "description": "cost latency spans telemetry self learning reports",
                    },
                    {
                        "name": "router",
                        "description": "delegate codex isolated worktree metered diffs",
                    },
                ]
            }
        ),
        encoding="utf-8",
    )

    result = bench.run_eval_case(
        {
            "type": "eval",
            "prompt": "show latency and cost from telemetry spans",
            "expect": "obs",
            "expect_type": "plugin",
            "scope": "plugin",
        },
        str(repo),
    )

    assert result["ok"] is True
    assert result["metrics"]["eval_in_top1"] == 1


def test_compare_and_gate_detect_quality_regression():
    baseline = {
        "schema": bench.SUMMARY_SCHEMA,
        "run_id": "base",
        "suite": "core",
        "metrics": {
            "score": 1.0,
            "pass_rate": 1.0,
            "required_pass_rate": 1.0,
            "required_fail": 0,
            "false_success": 0,
        },
        "gate": {"allow_neutral": True, "max_false_success_delta": 0},
    }
    candidate = {
        "schema": bench.SUMMARY_SCHEMA,
        "run_id": "cand",
        "suite": "core",
        "metrics": {
            "score": 0.5,
            "pass_rate": 0.5,
            "required_pass_rate": 0.5,
            "required_fail": 1,
            "false_success": 1,
        },
        "gate": {"allow_neutral": True, "max_false_success_delta": 0},
    }

    comparison = bench.compare_summaries(baseline, candidate)
    decision = bench.gate_decision(comparison, candidate["gate"])

    assert comparison["status"] == "regressed"
    assert "pass_rate" in comparison["quality_regressions"]
    assert "false_success" in comparison["quality_regressions"]
    assert decision["status"] == "fail"


def test_gate_allows_neutral_candidate_by_default():
    summary = {
        "schema": bench.SUMMARY_SCHEMA,
        "run_id": "same",
        "suite": "core",
        "metrics": {
            "score": 1.0,
            "pass_rate": 1.0,
            "required_pass_rate": 1.0,
            "required_fail": 0,
            "false_success": 0,
        },
        "gate": {"allow_neutral": True, "max_false_success_delta": 0},
    }

    comparison = bench.compare_summaries(summary, summary)
    decision = bench.gate_decision(comparison, summary["gate"])

    assert comparison["status"] == "neutral"
    assert decision["status"] == "pass"


def test_record_failed_outcomes_writes_benchmark_source(tmp_path):
    logs = tmp_path / "logs"
    run_path = tmp_path / "bench" / "run.json"
    run_path.parent.mkdir()
    run_path.write_text("{}", encoding="utf-8")
    results = [
        {
            "id": "eval.fail",
            "type": "eval",
            "required": True,
            "status": "fail",
            "reason": "expect=legion-router got=legion-observability",
            "target_type": "plugin",
            "target_name": "legion-router",
            "details": {"got": "legion-observability"},
        }
    ]

    recorded = bench.record_failed_outcomes(
        results,
        log_root=str(logs),
        run_path=str(run_path),
        run_id="bench-1",
        suite_name="core",
    )
    recorded_again = bench.record_failed_outcomes(
        results,
        log_root=str(logs),
        run_path=str(run_path),
        run_id="bench-2",
        suite_name="core",
    )

    assert len(recorded) == 1
    assert recorded_again == []
    outcome = json.loads((logs / "self-learn" / "outcomes.jsonl").read_text(encoding="utf-8"))
    assert outcome["schema"] == bench.OUTCOME_SCHEMA
    assert outcome["source"] == "legion-bench"
    assert outcome["target_type"] == "plugin"
    assert outcome["target_name"] == "legion-router"


def test_task_case_runs_fixture_command_and_validators(tmp_path):
    run_dir = tmp_path / "run"
    script = (
        "import json, pathlib, sys\n"
        "pathlib.Path('result.json').write_text(json.dumps({'ok': True}) + '\\n')\n"
        "print(json.dumps({'status': 'done', 'items': [{'kind': 'fixture'}]}))\n"
    )

    result = bench.run_task_case(
        {
            "id": "task.fixture",
            "type": "task",
            "files": {"input.txt": "hello"},
            "command": ["python3", "-c", script],
            "validators": [
                {"type": "file_exists", "path": "{workspace}/result.json"},
                {
                    "type": "json_file_field_equals",
                    "path": "{workspace}/result.json",
                    "field": "ok",
                    "equals": True,
                },
                {
                    "type": "stdout_json_field_equals",
                    "field": "items.0.kind",
                    "equals": "fixture",
                },
            ],
        },
        str(tmp_path),
        str(run_dir),
    )

    assert result["ok"] is True
    assert result["metrics"]["task_pass"] == 1
    assert all(item["ok"] for item in result["details"]["validators"])


def test_task_case_validates_jsonl_contains(tmp_path):
    run_dir = tmp_path / "run"
    script = (
        "import json, pathlib\n"
        "pathlib.Path('events.jsonl').write_text(json.dumps({'source': 'bench', 'nested': {'id': 'x'}}) + '\\n')\n"
    )

    result = bench.run_task_case(
        {
            "id": "task.jsonl",
            "type": "task",
            "command": ["python3", "-c", script],
            "validators": [
                {
                    "type": "jsonl_contains",
                    "path": "{workspace}/events.jsonl",
                    "match": {"source": "bench", "nested": {"id": "x"}},
                }
            ],
        },
        str(tmp_path),
        str(run_dir),
    )

    assert result["ok"] is True


def test_write_run_artifacts_and_span(tmp_path):
    suite = {"suite": "core", "_path": str(tmp_path / "core.json")}
    results = [
        {
            "schema": bench.CASE_RESULT_SCHEMA,
            "id": "case",
            "type": "eval",
            "required": True,
            "status": "pass",
            "ok": True,
            "metrics": {},
        }
    ]
    summary = {
        "schema": bench.SUMMARY_SCHEMA,
        "run_id": "bench-run",
        "suite": "core",
        "generated_at": "2026-06-27T00:00:00Z",
        "repo": str(tmp_path),
        "commit": "abc123",
        "ok": True,
        "metrics": {"duration_ms": 5},
    }

    artifacts = bench.write_run_artifacts(str(tmp_path / "bench"), "bench-run", suite, results, summary)
    span_path = bench.emit_bench_span(summary, artifacts, str(tmp_path / "spans"))

    assert os.path.exists(artifacts["run_path"])
    assert os.path.exists(artifacts["summary_path"])
    assert os.path.exists(artifacts["cases_path"])
    assert os.path.exists(span_path)
    span = json.loads(open(span_path, encoding="utf-8").read())
    assert span["executor"] == "legion-bench"
    assert span["artifacts"]["bench_run"] == artifacts["run_path"]
