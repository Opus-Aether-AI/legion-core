import argparse
import importlib.util
import json
import os
import subprocess


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


def test_resolve_suite_path_prefers_packaged_json_over_matching_directory():
    repo = os.path.abspath(os.path.join(HERE, "..", ".."))

    path = bench.resolve_suite_path(repo, "legion-run")

    assert os.path.isfile(path)
    assert path.endswith(os.path.join("legion-observability", "bench", "legion-run.json"))


def test_codex_live_adapter_validator_covers_review_discovered_edges():
    repo = os.path.abspath(os.path.join(HERE, "..", ".."))
    adapter = os.path.join(
        repo,
        "legion-observability",
        "bench",
        "adapters",
        "legion-run-direct-codex-live.sh",
    )
    text = open(adapter, encoding="utf-8").read()

    assert "Walk-in cooler" in text
    assert "Refrigerator" in text
    assert "Interior light failed" in text
    assert "Walk-in entrance door" in text
    assert "Emergency exit is blocked" in text
    assert "Temperature rising. Product warming reported" in text
    assert "Refrigerant leak detected" in text
    assert 'tags=["freezer", "down"]' in text
    assert 'tags=["down", "freezer"]' in text


def test_codex_live_suite_validates_business_proof_not_only_green_path():
    repo = os.path.abspath(os.path.join(HERE, "..", ".."))
    suite = bench.load_suite(repo, "legion-run-codex-live")
    validators = suite["cases"][0]["validators"]
    case = suite["cases"][0]
    fields = {
        item.get("field")
        for item in validators
        if item.get("type") == "stdout_json_field_equals"
    }
    file_contains = {
        item.get("text")
        for item in validators
        if item.get("type") == "file_contains"
    }

    assert case["timeout"] >= 2400
    assert "checks.live_codex_pipeline_proved" in fields
    assert "checks.quality_feedback_recorded" in fields
    assert "checks.self_learning_memory_updated_by_feedback" in fields
    assert "checks.business_proof_complete" in fields
    assert "checks.validate_command_used" not in fields
    assert "checks.coding_task_implemented" not in fields
    assert "Validation And Review-Discovered Learning" in file_contains


def test_load_corpus_reads_packaged_local_smoke():
    repo = os.path.abspath(os.path.join(HERE, "..", ".."))
    corpus = bench.load_corpus(repo, "local-smoke")

    assert corpus["corpus"] == "local-smoke"
    assert len(corpus["modes"]) == 2
    assert len(corpus["cases"]) == 3


def test_run_command_resolves_default_state_from_target_repo(tmp_path, monkeypatch, capsys):
    repo = tmp_path / "app"
    repo.mkdir()
    home = tmp_path / "home"
    monkeypatch.setenv("HOME", str(home))
    for key in ("LEGION_STATE_ROOT", "LEGION_BENCH_DIR", "LEGION_TELEMETRY_DIR"):
        monkeypatch.delenv(key, raising=False)

    suite = {"schema": bench.SUITE_SCHEMA, "suite": "core", "cases": []}

    def fake_run_suite_artifacts(repo, suite, bench_dir, run_id):
        assert repo == str(tmp_path / "app")
        assert bench_dir.startswith(str(home / ".legion" / "projects"))
        return {
            "results": [],
            "summary": {"ok": True, "metrics": {"cases": 0, "pass": 0, "fail": 0}},
            "artifacts": {"run_path": os.path.join(bench_dir, "run.json"), "summary_path": os.path.join(bench_dir, "summary.json")},
        }

    def fake_emit_bench_span(summary, artifacts, telemetry_dir):
        assert telemetry_dir.startswith(str(home / ".legion" / "projects"))
        return os.path.join(telemetry_dir, "span.jsonl")

    monkeypatch.setattr(bench, "load_suite", lambda repo, suite_name: suite)
    monkeypatch.setattr(bench, "_run_suite_artifacts", fake_run_suite_artifacts)
    monkeypatch.setattr(bench, "emit_bench_span", fake_emit_bench_span)

    args = argparse.Namespace(
        repo=str(repo),
        suite="core",
        bench_dir="",
        logs="",
        telemetry_dir="",
        run_id="state-test",
        record_failures=False,
        strict=True,
        json=True,
        quiet=True,
    )

    assert bench.run_command(args) == 0
    payload = json.loads(capsys.readouterr().out)
    assert payload["summary"]["ok"] is True


def test_load_corpus_reads_packaged_heldout_default_modes():
    repo = os.path.abspath(os.path.join(HERE, "..", ".."))
    corpus = bench.load_corpus(repo, "heldout-oss-36")
    modes = bench._selected_corpus_modes(corpus, [])

    assert corpus["corpus"] == "heldout-oss-36"
    assert len(corpus["cases"]) == 36
    assert [mode["id"] for mode in modes] == ["scripted-baseline", "scripted-oracle"]


def test_load_corpus_reads_packaged_fieldops_e2e_live_mode():
    repo = os.path.abspath(os.path.join(HERE, "..", ".."))
    corpus = bench.load_corpus(repo, "fieldops-triage-e2e")
    default_modes = bench._selected_corpus_modes(corpus, [])
    live_modes = bench._selected_corpus_modes(corpus, ["legion-fanout-review"])
    case = corpus["cases"][0]
    live_validators = case["validators_by_mode"]["legion-fanout-review"]
    checked_fields = {
        validator.get("field")
        for validator in live_validators
        if validator.get("type") == "json_file_field_equals"
    }

    assert corpus["corpus"] == "fieldops-triage-e2e"
    assert len(corpus["cases"]) == 1
    assert "one coding task can route, fan out, apply code, review" in corpus["description"]
    assert "still cold" in case["task"]
    assert "No heat in the classroom but the room is still cold." in case["files"]["eval_fieldops_triage.py"]
    assert [mode["id"] for mode in default_modes] == ["scripted-baseline", "scripted-oracle"]
    assert live_modes[0]["live"] is True
    assert live_modes[0]["command"] == ["{repo}/legion-observability/bench/adapters/legion-fanout-review.sh"]
    assert live_modes[0]["timeout"] >= 2400
    assert {
        "slices",
        "applied",
        "status",
        "total.success_rate",
        "groups.codex-review.success_rate",
        "target_name",
        "applied_memory",
        "scorecard.ok",
        "summary.ok",
    }.issubset(checked_fields)


def test_fieldops_pipeline_report_renderer_embeds_full_artifact_trail(tmp_path):
    workspace = tmp_path / "workspace"
    workspace.mkdir()
    task_file = tmp_path / "task.txt"
    task_file.write_text("Implement the FieldOps scorer.", encoding="utf-8")
    diff = workspace / "diff.patch"
    diff.write_text("diff --git a/fieldops_triage.py b/fieldops_triage.py\n", encoding="utf-8")
    payloads = {
        "doctor.json": [
            {"check": "codex", "severity": "pass", "message": "codex present"},
            {"check": "router", "severity": "warn", "message": "optional router"},
        ],
        "route-implement.json": {"resolved": True, "executor": "codex", "model": "gpt-5.5", "sandbox": "workspace-write"},
        "route-review.json": {"resolved": True, "executor": "codex-review", "model": "gpt-5.5"},
        "fanout.json": {
            "slices": 1,
            "ok": 1,
            "failed": 0,
            "applied": 1,
            "apply_conflicts": 0,
            "results": [{"diff_path": str(diff)}],
        },
        "review.json": {"status": "ok", "model": "gpt-5.5", "verdict": "Looks good."},
        "score.json": {"passed": True, "score": 7, "total": 7, "failures": {}},
        "legion-report.json": {
            "groups": {"codex": {"count": 1, "ok": 1, "success_rate": 1.0, "cost_usd": 0.1, "p50_ms": 10, "p95_ms": 10}},
            "total": {"count": 1, "ok": 1, "success_rate": 1.0, "cost_usd": 0.1},
        },
        "legion-share.json": {"status": "met", "failed_runs": 0, "codex_runs": 1},
        "self-learn-record.json": {"target_type": "benchmark", "target_name": "fieldops-triage-e2e"},
        "self-learn-hints.json": {"schema": "legion.self-learning.hints.v1"},
        "self-learn-run.json": {
            "applied_memory": True,
            "by_entity": {"benchmark:fieldops-triage-e2e": 1},
            "summary": {"outcomes": 1},
            "scorecard": {"ok": True},
        },
        "heal-plan.json": {"total": 0, "fixable": 0, "findings": []},
        "bench-core.json": {"summary": {"ok": True, "metrics": {"pass": 10, "fail": 0}}},
    }
    for name, payload in payloads.items():
        (workspace / name).write_text(json.dumps(payload), encoding="utf-8")
    (workspace / "fieldops_triage.py").write_text("def triage_ticket(message, inventory=None):\n    return {}\n", encoding="utf-8")
    (workspace / "legion-observability.html").write_text("<!doctype html>Legion Observability Report\n", encoding="utf-8")

    script = os.path.abspath(os.path.join(
        HERE,
        "..",
        "..",
        "legion-observability",
        "bench",
        "adapters",
        "render-fieldops-pipeline-report.py",
    ))
    output = workspace / "legion-report.html"
    proc = subprocess.run(
        ["python3", script, "--workspace", str(workspace), "--task-file", str(task_file), "--output", str(output)],
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        timeout=10,
    )

    assert proc.returncode == 0, proc.stderr
    html = output.read_text(encoding="utf-8")
    assert "Legion Full Pipeline Report" in html
    assert "Pipeline Timeline" in html
    assert "Raw JSON Evidence" in html
    assert "Applied diff from Legion delegate" in html
    assert "legion-observability.html" in html
    assert "7/7" in html


def test_packaged_live_corpora_default_to_no_spend_controls():
    repo = os.path.abspath(os.path.join(HERE, "..", ".."))

    for corpus_name in ("heldout-oss-hard", "aider-polyglot-python"):
        corpus = bench.load_corpus(repo, corpus_name)
        modes = bench._selected_corpus_modes(corpus, [])

        assert [mode["id"] for mode in modes] == ["scripted-baseline", "scripted-oracle"]
        assert not any(mode.get("live") for mode in modes)


def test_load_suite_extends_relative_to_absolute_suite_path(tmp_path):
    repo = tmp_path / "target-repo"
    repo.mkdir()
    suites = tmp_path / "suites"
    suites.mkdir()
    (suites / "core.json").write_text(
        json.dumps({
            "schema": bench.SUITE_SCHEMA,
            "suite": "core",
            "cases": [{"id": "base", "type": "route", "archetype": "x"}],
        }),
        encoding="utf-8",
    )
    stable = suites / "stable.json"
    stable.write_text(
        json.dumps({
            "schema": bench.SUITE_SCHEMA,
            "suite": "stable",
            "extends": ["core"],
            "cases": [{"id": "extra", "type": "route", "archetype": "y"}],
        }),
        encoding="utf-8",
    )

    suite = bench.load_suite(str(repo), str(stable))

    assert [case["id"] for case in suite["cases"]] == ["base", "extra"]


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


def test_record_failed_corpus_outcomes_attributes_to_mode(tmp_path):
    logs = tmp_path / "logs"
    run_path = tmp_path / "bench" / "run.json"
    run_path.parent.mkdir()
    run_path.write_text("{}", encoding="utf-8")
    results = [
        {
            "id": "py-parse-bool",
            "mode": "legion-delegate",
            "required": True,
            "status": "fail",
            "dimension": "parsing",
            "attempt": 2,
            "reason": "exit=1 expected=0; validators=0/1",
        },
        {
            "id": "py-add",
            "mode": "legion-delegate",
            "required": True,
            "status": "pass",
            "dimension": "implementation",
            "reason": "case passed",
        },
    ]

    recorded = bench.record_failed_corpus_outcomes(
        results,
        log_root=str(logs),
        run_path=str(run_path),
        run_id="corpus-1",
        corpus_name="heldout-oss-36",
    )
    recorded_again = bench.record_failed_corpus_outcomes(
        results,
        log_root=str(logs),
        run_path=str(run_path),
        run_id="corpus-2",
        corpus_name="heldout-oss-36",
    )

    assert len(recorded) == 1
    assert recorded_again == []
    outcome = json.loads((logs / "self-learn" / "outcomes.jsonl").read_text(encoding="utf-8"))
    assert outcome["source"] == "legion-bench"
    assert outcome["target_type"] == "command"
    assert outcome["target_name"] == "legion-delegate"
    assert outcome["metadata"]["corpus"] == "heldout-oss-36"
    assert outcome["metadata"]["mode"] == "legion-delegate"


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


def test_task_case_validates_command_validator(tmp_path):
    result = bench.run_task_case(
        {
            "id": "task.command-validator",
            "type": "task",
            "files": {
                "app.py": "VALUE = 7\n",
                "test_app.py": "from app import VALUE\nassert VALUE == 7\n",
            },
            "command": ["python3", "-c", "print('ready')"],
            "validators": [
                {
                    "type": "command",
                    "command": ["python3", "test_app.py"],
                    "cwd": "{workspace}",
                }
            ],
        },
        str(tmp_path),
        str(tmp_path / "run"),
    )

    assert result["ok"] is True
    assert result["details"]["validators"][0]["type"] == "command"


def test_corpus_case_exports_real_home_for_live_adapters(tmp_path):
    repo = os.path.abspath(os.path.join(HERE, "..", ".."))
    result = bench.run_corpus_case_mode(
        {
            "id": "env-export",
            "type": "task",
            "task": "Record benchmark environment.",
            "command": [
                "python3",
                "-c",
                (
                    "import json, os, pathlib; "
                    "pathlib.Path('env.json').write_text(json.dumps({"
                    "'home': os.environ.get('HOME'), "
                    "'bench_home': os.environ.get('LEGION_BENCH_HOME'), "
                    "'real_home': os.environ.get('LEGION_BENCH_REAL_HOME')"
                    "}), encoding='utf-8')"
                ),
            ],
            "validators": [
                {
                    "type": "json_file_field_equals",
                    "path": "{workspace}/env.json",
                    "field": "real_home",
                    "equals": os.environ["HOME"],
                }
            ],
        },
        {"id": "env-mode"},
        repo=repo,
        run_dir=str(tmp_path / "run"),
        repeat_index=1,
    )

    env_path = (
        tmp_path
        / "run"
        / "corpus-workspaces"
        / "env-mode"
        / "attempt-01"
        / "env-export"
        / "env.json"
    )
    env = json.loads(env_path.read_text(encoding="utf-8"))
    assert result["status"] == "pass"
    assert env["home"] == env["bench_home"]
    assert env["real_home"] == os.environ["HOME"]
    assert env["home"] != env["real_home"]


def test_corpus_case_exports_coherent_legion_state(tmp_path):
    repo = os.path.abspath(os.path.join(HERE, "..", ".."))
    result = bench.run_corpus_case_mode(
        {
            "id": "state-export",
            "type": "task",
            "task": "Record benchmark state environment.",
            "command": [
                "python3",
                "-c",
                (
                    "import json, os, pathlib; "
                    "pathlib.Path('state-env.json').write_text(json.dumps({"
                    "'logs': os.environ.get('LEGION_BENCH_LOGS'), "
                    "'state_root': os.environ.get('LEGION_STATE_ROOT'), "
                    "'telemetry_dir': os.environ.get('LEGION_TELEMETRY_DIR'), "
                    "'registry_dir': os.environ.get('LEGION_REGISTRY_DIR'), "
                    "'repos_file': os.environ.get('LEGION_REPOS_FILE'), "
                    "'bench_dir': os.environ.get('LEGION_BENCH_DIR'), "
                    "'reports_dir': os.environ.get('LEGION_REPORTS_DIR')"
                    "}), encoding='utf-8')"
                ),
            ],
            "validators": [
                {
                    "type": "json_file_field_equals",
                    "path": "{workspace}/state-env.json",
                    "field": "state_root",
                    "equals": "{logs}",
                }
            ],
        },
        {"id": "state-mode"},
        repo=repo,
        run_dir=str(tmp_path / "run"),
        repeat_index=1,
    )

    env_path = (
        tmp_path
        / "run"
        / "corpus-workspaces"
        / "state-mode"
        / "attempt-01"
        / "state-export"
        / "state-env.json"
    )
    env = json.loads(env_path.read_text(encoding="utf-8"))
    assert result["status"] == "pass"
    assert env["state_root"] == env["logs"]
    assert env["telemetry_dir"] == os.path.join(env["state_root"], "spans")
    assert env["registry_dir"] == os.path.join(env["state_root"], "registry")
    assert env["repos_file"] == os.path.join(env["state_root"], "repos.jsonl")
    assert env["bench_dir"] == os.path.join(env["state_root"], "bench")
    assert env["reports_dir"] == os.path.join(env["state_root"], "reports")


def test_corpus_summary_fails_selected_mode_when_clean_mode_not_selected(tmp_path):
    summary = bench.summarize_corpus_run(
        {
            "corpus": "fieldops-triage-e2e",
            "required_clean_modes": ["scripted-oracle"],
        },
        [
            {
                "id": "fieldops",
                "mode": "legion-fanout-review",
                "status": "fail",
                "ok": False,
                "required": True,
                "dimension": "agentic-e2e",
                "metrics": {"duration_ms": 10},
                "reason": "exit=1 expected=0",
            }
        ],
        run_id="live-only",
        repo=str(tmp_path),
        baseline_mode="legion-fanout-review",
        reliability_min_cases=30,
    )

    assert summary["required_clean_modes"] == []
    assert summary["modes"]["legion-fanout-review"]["metrics"]["required_fail"] == 1
    assert summary["ok"] is False


def test_corpus_case_marks_provider_usage_limit_as_blocked(tmp_path):
    repo = os.path.abspath(os.path.join(HERE, "..", ".."))

    result = bench.run_corpus_case_mode(
        {
            "id": "quota-case",
            "type": "task",
            "task": "This model call should be treated as provider-blocked.",
            "command": [
                "python3",
                "-c",
                (
                    "print(\"You've hit your usage limit. try again at 8:46 PM.\"); "
                    "raise SystemExit(1)"
                ),
            ],
            "validators": [
                {
                    "type": "command",
                    "command": ["python3", "-c", "raise SystemExit(99)"],
                }
            ],
        },
        {"id": "live-mode"},
        repo=repo,
        run_dir=str(tmp_path / "run"),
        repeat_index=1,
    )

    assert result["status"] == "blocked"
    assert result["reason"] == "provider_usage_limit"
    assert result["details"]["provider_blocked"] is True
    assert result["details"]["validators"] == []


def test_span_totals_roll_up_by_model(tmp_path):
    spans = tmp_path / "logs" / "spans"
    spans.mkdir(parents=True)
    (spans / "2026-06-27.jsonl").write_text(
        "\n".join([
            json.dumps({
                "schema": "legion.span.v1",
                "model": "composer-2.5",
                "cost_usd": 0,
                "duration_ms": 10,
                "tokens": {"input_tokens": 100, "output_tokens": 20},
            }),
            json.dumps({
                "schema": "legion.span.v1",
                "model": "gpt-5.5",
                "cost_usd": 0.5,
                "duration_ms": 30,
                "tokens": {"total_tokens": 90},
            }),
        ])
        + "\n",
        encoding="utf-8",
    )

    totals = bench._span_totals(str(tmp_path / "logs"))

    assert totals["span_count"] == 2
    assert totals["tokens"] == 210
    assert totals["models"]["composer-2.5"]["tokens"] == 120
    assert totals["models"]["gpt-5.5"]["cost_usd"] == 0.5


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


def test_corpus_plan_marks_heldout_reliable():
    repo = os.path.abspath(os.path.join(HERE, "..", ".."))
    corpus = bench.load_corpus(repo, "heldout-oss-36")
    modes = bench._selected_corpus_modes(corpus, [])
    plan = bench.corpus_plan(
        corpus,
        modes,
        baseline_mode="scripted-baseline",
        repeat=1,
        reliability_min_cases=30,
    )

    assert plan["case_count"] == 36
    assert plan["total_case_runs"] == 72
    assert plan["comparisons"]["scripted-baseline..scripted-oracle"]["reliable"] is True
    assert plan["has_live_modes_selected"] is False


def test_corpus_summary_reports_paired_stats_and_failure_clusters(tmp_path):
    repo = os.path.abspath(os.path.join(HERE, "..", ".."))
    corpus = bench.load_corpus(repo, "heldout-oss-36")
    modes = bench._selected_corpus_modes(corpus, [])
    run_dir = tmp_path / "heldout"
    results = []
    for mode in modes:
        for case in corpus["cases"][:3]:
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
        {**corpus, "required_clean_modes": ["scripted-oracle"]},
        results,
        run_id="heldout-test",
        repo=repo,
        baseline_mode="scripted-baseline",
        reliability_min_cases=3,
    )
    comparison = summary["comparisons"]["scripted-baseline..scripted-oracle"]

    assert summary["ok"] is True
    assert summary["modes"]["scripted-baseline"]["metrics"]["pass"] == 0
    assert summary["modes"]["scripted-oracle"]["metrics"]["pass"] == 3
    assert comparison["paired"]["candidate_only_pass"] == 3
    assert comparison["paired"]["baseline_only_pass"] == 0
    assert comparison["paired"]["significant_95"] is False
    assert summary["failure_clusters"]


def test_corpus_summary_allows_live_modes_without_clean_control():
    corpus = {
        "corpus": "live-demo",
        "required_clean_modes": ["scripted-oracle"],
    }
    results = [
        {
            "id": "case-1",
            "attempt": 1,
            "mode": "direct-codex",
            "dimension": "implementation",
            "required": True,
            "status": "fail",
            "reason": "validator failed",
            "metrics": {"duration_ms": 10, "cost_usd": 0.01, "tokens": 100},
        },
        {
            "id": "case-1",
            "attempt": 1,
            "mode": "legion-delegate",
            "dimension": "implementation",
            "required": True,
            "status": "pass",
            "metrics": {"duration_ms": 12, "cost_usd": 0.02, "tokens": 120},
        },
    ]

    summary = bench.summarize_corpus_run(
        corpus,
        results,
        run_id="live-demo",
        repo=".",
        baseline_mode="direct-codex",
        reliability_min_cases=1,
    )

    comparison = summary["comparisons"]["direct-codex..legion-delegate"]
    assert summary["ok"] is True
    assert summary["required_clean_modes"] == []
    assert comparison["paired"]["candidate_only_pass"] == 1
    assert comparison["reliable"] is True


def test_render_corpus_markdown_includes_paired_table():
    summary = {
        "corpus": "demo",
        "generated_at": "2026-06-27T00:00:00Z",
        "run_id": "run",
        "commit": "abc",
        "baseline_mode": "base",
        "reliability_min_cases": 30,
        "modes": {
            "base": {
                "metrics": {
                    "pass": 1,
                    "blocked": 1,
                    "case_runs": 2,
                    "pass_rate": 0.5,
                    "pass_rate_ci95": {"low": 0.1, "high": 0.9},
                    "cost_usd": 0,
                    "tokens": 0,
                    "span_count": 1,
                    "models": {
                        "gpt-5.5": {
                            "span_count": 1,
                            "cost_usd": 0,
                            "tokens": 0,
                            "span_duration_ms": 10,
                        }
                    },
                    "mean_duration_ms": 10,
                    "p95_duration_ms": 12,
                }
            },
            "cand": {
                "metrics": {
                    "pass": 2,
                    "blocked": 0,
                    "case_runs": 2,
                    "pass_rate": 1,
                    "pass_rate_ci95": {"low": 0.2, "high": 1},
                    "cost_usd": 0,
                    "tokens": 0,
                    "span_count": 1,
                    "models": {
                        "composer-2.5": {
                            "span_count": 1,
                            "cost_usd": 0,
                            "tokens": 0,
                            "span_duration_ms": 11,
                        }
                    },
                    "mean_duration_ms": 11,
                    "p95_duration_ms": 13,
                }
            },
        },
        "comparisons": {
            "base..cand": {
                "delta_pct_points": 50,
                "relative_improvement_pct": 100,
                "reliable": False,
                "paired": {
                    "candidate_only_pass": 1,
                    "baseline_only_pass": 0,
                    "mcnemar_exact_p_value": 1.0,
                },
                "cost_usd_delta": 0,
                "duration_ms_delta": 1,
            }
        },
        "failure_clusters": [],
    }

    markdown = bench.render_corpus_markdown(summary, {"run_path": "/tmp/run.json"})

    assert "Mode Results" in markdown
    assert "| Mode | Pass | Blocked | Case-runs |" in markdown
    assert "Model Metering" in markdown
    assert "`composer-2.5`" in markdown
    assert "Candidate paired wins" in markdown
    assert "`base..cand`" in markdown


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


def test_write_run_artifacts_summarizes_nested_legion_run_learning(tmp_path):
    logs = tmp_path / "workspace" / "logs"
    run_dir = logs / "runs" / "legion-run" / "20260711T140238Z-direct"
    run_dir.mkdir(parents=True)
    (run_dir / "learning-feedback.json").write_text(
        json.dumps({"recorded": 1, "outcomes_path": str(logs / "self-learn" / "outcomes.jsonl")}),
        encoding="utf-8",
    )
    (run_dir / "self-learn.json").write_text(
        json.dumps({
            "run": {
                "applied_memory": True,
                "summary": {"outcomes": 4},
                "memory_path": str(logs / "self-learn" / "harness-memory.json"),
                "report_path": str(logs / "self-learn" / "reports" / "2026-07-11.json"),
            },
            "learning_feedback": {"recorded": 1},
        }),
        encoding="utf-8",
    )
    results = [
        {
            "schema": bench.CASE_RESULT_SCHEMA,
            "id": "task.legion-run",
            "type": "task",
            "required": True,
            "status": "pass",
            "ok": True,
            "metrics": {},
            "details": {"logs": str(logs)},
        }
    ]
    summary = {
        "schema": bench.SUMMARY_SCHEMA,
        "run_id": "bench-run",
        "suite": "legion-run",
        "generated_at": "2026-07-11T00:00:00Z",
        "repo": str(tmp_path),
        "commit": "abc123",
        "ok": True,
        "metrics": {"duration_ms": 5},
    }

    artifacts = bench.write_run_artifacts(str(tmp_path / "bench"), "bench-run", {}, results, summary)
    run_payload = json.loads(open(artifacts["run_path"], encoding="utf-8").read())

    nested = artifacts["legion_run_self_learning"]
    assert nested["recorded_outcomes"] == 1
    assert nested["applied_memory_runs"] == 1
    assert nested["self_learn_summary_outcomes"] == 4
    assert nested["cases"]["task.legion-run"]["runs"][0]["applied_memory"] is True
    assert run_payload["artifacts"]["legion_run_self_learning"]["recorded_outcomes"] == 1
