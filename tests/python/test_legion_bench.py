import argparse
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


def test_compare_reports_headline_relative_lift():
    baseline = {
        "schema": bench.SUMMARY_SCHEMA,
        "run_id": "base",
        "suite": "core",
        "metrics": {"score": 0.79, "pass_rate": 0.79, "required_fail": 0, "false_success": 0},
    }
    candidate = {
        "schema": bench.SUMMARY_SCHEMA,
        "run_id": "cand",
        "suite": "core",
        "metrics": {"score": 0.93, "pass_rate": 0.93, "required_fail": 0, "false_success": 0},
    }

    comparison = bench.compare_summaries(baseline, candidate)

    assert comparison["status"] == "improved"
    assert comparison["headline"]["delta_pct_points"] == 14.0
    assert comparison["headline"]["relative_improvement_pct"] == 17.722
    assert comparison["metrics"]["pass_rate"]["relative_improvement_pct"] == 17.722


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


def test_load_suite_extends_core_cases():
    repo = os.path.abspath(os.path.join(HERE, "..", ".."))
    suite = bench.load_suite(repo, "stable")
    ids = {case["id"] for case in suite["cases"]}

    assert "eval.plugin.observability" in ids
    assert "route.perf-optimization" in ids
    assert len(suite["cases"]) >= 43


def test_load_corpus_reads_packaged_local_smoke():
    repo = os.path.abspath(os.path.join(HERE, "..", ".."))
    corpus = bench.load_corpus(repo, "local-smoke")

    assert corpus["corpus"] == "local-smoke"
    assert len(corpus["modes"]) == 2
    assert len(corpus["cases"]) == 3


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


def test_learning_lift_payload_scores_before_after_memory(tmp_path):
    repo = os.path.abspath(os.path.join(HERE, "..", ".."))
    payload = bench.learning_lift_payload(
        argparse.Namespace(
            repo=repo,
            bench_dir=str(tmp_path / "bench"),
            logs="",
            telemetry_dir=str(tmp_path / "spans"),
            run_id="lift-test",
            correction="u should have linked the right harness bench repo, wrong attribution source",
        )
    )

    lift = payload["learning_lift"]
    assert payload["comparison"]["status"] == "improved"
    assert payload["baseline"]["summary"]["metrics"]["learning_pass"] == 1
    assert payload["candidate"]["summary"]["metrics"]["learning_pass"] == 4
    assert lift["delta_pct_points"] == 75.0
    assert lift["relative_lift_reliable"] is False
    assert lift["headline_metric"] == "delta_pct_points"
    assert os.path.exists(payload["baseline"]["artifacts"]["run_path"])
    assert os.path.exists(payload["candidate"]["artifacts"]["run_path"])


def test_stability_rollup_detects_flakes():
    suite = {"suite": "stable"}
    pass_result = {
        "id": "case",
        "dimension": "routing",
        "status": "pass",
        "required": True,
    }
    fail_result = {
        "id": "case",
        "dimension": "routing",
        "status": "fail",
        "required": True,
    }
    iterations = [
        {
            "summary": {
                "run_id": "iter-1",
                "metrics": {"score": 1.0, "pass_rate": 1.0, "cases": 1, "required_fail": 0},
                "dimensions": {"routing": {"cases": 1, "pass": 1, "fail": 0, "required_fail": 0}},
            },
            "results": [pass_result],
            "artifacts": {"run_path": "run-1", "summary_path": "summary-1"},
        },
        {
            "summary": {
                "run_id": "iter-2",
                "metrics": {"score": 0.0, "pass_rate": 0.0, "cases": 1, "required_fail": 1},
                "dimensions": {"routing": {"cases": 1, "pass": 0, "fail": 1, "required_fail": 1}},
            },
            "results": [fail_result],
            "artifacts": {"run_path": "run-2", "summary_path": "summary-2"},
        },
    ]

    rollup = bench.stability_rollup(suite, iterations, run_id="stable-1", repo=".")

    assert rollup["ok"] is False
    assert rollup["metrics"]["flake_count"] == 1
    assert rollup["metrics"]["min_score"] == 0.0
    assert rollup["flake_cases"][0]["id"] == "case"


def test_corpus_runner_reports_mode_lift_and_reliability(tmp_path):
    repo = os.path.abspath(os.path.join(HERE, "..", ".."))
    corpus = bench.load_corpus(repo, "local-smoke")
    modes = bench._selected_corpus_modes(corpus, [])
    run_dir = tmp_path / "corpus-run"
    results = []
    for mode in modes:
        for case in corpus["cases"]:
            results.append(
                bench.run_corpus_case_mode(
                    case,
                    mode,
                    repo=repo,
                    run_dir=str(run_dir),
                    repeat_index=1,
                )
            )

    summary = bench.summarize_corpus_run(
        corpus,
        results,
        run_id="corpus-1",
        repo=repo,
        baseline_mode="control-baseline",
        reliability_min_cases=30,
    )

    baseline = summary["modes"]["control-baseline"]["metrics"]
    candidate = summary["modes"]["control-candidate"]["metrics"]
    comparison = summary["comparisons"]["control-baseline..control-candidate"]
    assert baseline["pass"] == 1
    assert candidate["pass"] == 3
    assert comparison["delta_pct_points"] == 66.667
    assert comparison["reliable"] is False


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
