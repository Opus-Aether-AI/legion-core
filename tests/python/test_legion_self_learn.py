import argparse
import importlib.util
import json
import os


HERE = os.path.dirname(__file__)
PATH = os.path.join(
    HERE, "..", "..", "legion-observability", "scripts", "legion-self-learn.py"
)
SPEC = importlib.util.spec_from_file_location("legion_self_learn", PATH)
self_learn = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(self_learn)


def test_default_repo_honors_legion_root_override(tmp_path, monkeypatch):
    # Location-agnostic: an explicit LEGION_ROOT wins over the script's layout.
    monkeypatch.setenv("LEGION_ROOT", str(tmp_path))
    assert self_learn.default_repo() == os.path.abspath(str(tmp_path))


def test_default_repo_falls_back_to_git_toplevel(monkeypatch):
    # With no override, the default resolves to the repo's git toplevel (where
    # the script lives), not a cwd-relative guess.
    monkeypatch.delenv("LEGION_ROOT", raising=False)
    repo_root = os.path.abspath(os.path.join(HERE, "..", ".."))
    assert self_learn.default_repo() == repo_root


def _catalog(tmp_path):
    command_path = tmp_path / "opus-commands" / "commands" / "feature.md"
    skill_path = tmp_path / "opus-commands" / "SKILL.md"
    command_path.parent.mkdir(parents=True, exist_ok=True)
    command_path.write_text("---\ndescription: Feature lane orchestrator\n---\n", encoding="utf-8")
    skill_path.write_text(
        "---\nname: workflow-orchestrator\ndescription: delivery workflow orchestrator\n---\n",
        encoding="utf-8",
    )
    return {
        "entities": [
            {
                "type": "command",
                "name": "feature",
                "plugin": "opus-commands",
                "description": "Feature lane orchestrator for delivery workflows",
                "source_path": str(command_path),
            },
            {
                "type": "skill",
                "name": "workflow-orchestrator",
                "plugin": "opus-commands",
                "description": "Cross-harness delivery workflow orchestrator",
                "source_path": str(skill_path),
            },
            {
                "type": "plugin",
                "name": "legion-router",
                "plugin": "legion-router",
                "description": "delegate codex metered routing",
                "source_path": str(tmp_path / "legion-router"),
            },
        ]
    }


def test_failed_span_attaches_to_narrow_command_entity(tmp_path):
    catalog = _catalog(tmp_path)
    spans = [
        {
            "schema": "legion.span.v1",
            "run_id": "run-1",
            "status": "failed",
            "executor": "codex",
            "model": "gpt-5.5",
            "task": "The /feature lane missed AGENTS.md release gates during planning.",
        }
    ]

    outcomes = self_learn.span_outcomes(spans, catalog)

    assert len(outcomes) == 1
    assert outcomes[0]["target_type"] == "command"
    assert outcomes[0]["target_name"] == "feature"
    proposal = self_learn.proposal_for_outcome(outcomes[0], catalog)
    assert proposal["kind"] == "run_failure_guardrail"
    assert proposal["source_path"].endswith("feature.md")


def test_failed_span_uses_explicit_target_metadata(tmp_path):
    catalog = _catalog(tmp_path)
    spans = [
        {
            "schema": "legion.span.v1",
            "run_id": "run-1",
            "status": "failed",
            "executor": "cursor",
            "model": "gpt-5",
            "task": "A vague task with no useful entity tokens.",
            "target_type": "skill",
            "target_name": "workflow-orchestrator",
        }
    ]

    outcomes = self_learn.span_outcomes(spans, catalog)

    assert len(outcomes) == 1
    assert outcomes[0]["target_type"] == "skill"
    assert outcomes[0]["target_name"] == "workflow-orchestrator"


def test_build_report_scores_only_requested_day(tmp_path, monkeypatch):
    repo = tmp_path / "repo"
    logs = tmp_path / "logs"
    spans = logs / "spans"
    spans.mkdir(parents=True)
    repo.mkdir()
    old = {
        "schema": "legion.span.v1",
        "ts": "2026-06-18T00:00:00Z",
        "run_id": "old",
        "status": "failed",
        "executor": "codex",
        "model": "gpt-5.5",
        "task": "/feature failed yesterday",
        "target_type": "command",
        "target_name": "feature",
    }
    new = {
        "schema": "legion.span.v1",
        "ts": "2026-06-19T00:00:00Z",
        "run_id": "new",
        "status": "ok",
        "executor": "codex",
        "model": "gpt-5.5",
        "task": "/feature passed today",
        "target_type": "command",
        "target_name": "feature",
    }
    (spans / "2026-06-18.jsonl").write_text(json.dumps(old) + "\n", encoding="utf-8")
    (spans / "2026-06-19.jsonl").write_text(json.dumps(new) + "\n", encoding="utf-8")
    monkeypatch.setattr(self_learn, "build_catalog", lambda _repo: _catalog(tmp_path))
    monkeypatch.setattr(self_learn, "trigger_eval_outcomes", lambda _repo, _catalog: [])
    monkeypatch.setattr(self_learn, "routing_outcomes", lambda _repo, _logs, _spans=None: [])

    report = self_learn.build_report(str(repo), str(logs), "2026-06-19")

    assert report["day"] == "2026-06-19"
    assert report["spans"] == 1
    assert report["outcomes"] == []


def test_build_report_scan_all_keeps_late_manual_outcomes(tmp_path, monkeypatch):
    repo = tmp_path / "repo"
    logs = tmp_path / "logs"
    repo.mkdir()
    monkeypatch.setattr(self_learn, "build_catalog", lambda _repo: _catalog(tmp_path))
    monkeypatch.setattr(self_learn, "trigger_eval_outcomes", lambda _repo, _catalog: [])
    monkeypatch.setattr(self_learn, "routing_outcomes", lambda _repo, _logs, _spans=None: [])
    outcome = {
        "schema": self_learn.OUTCOME_SCHEMA,
        "id": "late",
        "ts": "2026-06-19T23:00:00Z",
        "source": "manual",
        "target_type": "command",
        "target_name": "feature",
        "severity": "high",
        "summary": "Late bug after cron.",
        "evidence": "run-1",
        "run_id": "",
        "source_path": "",
        "metadata": {},
    }
    self_learn._append_jsonl(self_learn.outcomes_path(str(logs)), outcome)

    report = self_learn.build_report(str(repo), str(logs), "2026-06-20", scan_all=True)

    assert report["scan_scope"] == "all"
    assert report["outcomes"][0]["id"] == "late"


def test_over_budget_span_becomes_learning_outcome(tmp_path):
    catalog = _catalog(tmp_path)
    spans = [
        {
            "schema": "legion.span.v1",
            "run_id": "run-budget",
            "status": "over_budget",
            "executor": "codex",
            "model": "gpt-5.5",
            "task": "/feature exceeded token budget",
            "target_type": "command",
            "target_name": "feature",
        }
    ]

    outcomes = self_learn.span_outcomes(spans, catalog)

    assert len(outcomes) == 1
    assert outcomes[0]["severity"] == "medium"
    assert outcomes[0]["target_type"] == "command"
    assert outcomes[0]["target_name"] == "feature"


def test_manual_bug_record_becomes_active_memory_hint(tmp_path):
    logs = str(tmp_path / "logs")
    args = argparse.Namespace(
        logs=logs,
        entity="skill:workflow-orchestrator",
        summary="Workflow lane repeated a stale deploy instruction.",
        severity="high",
        source="review-gate",
        evidence="Finding in run-123",
        json=False,
    )

    outcome = self_learn.record_manual_outcome(args)
    report = {
        "generated_at": "2026-06-19T00:00:00Z",
        "outcomes": [outcome],
        "proposals": [
            {
                "id": "p1",
                "target_type": "skill",
                "target_name": "workflow-orchestrator",
                "severity": "high",
                "summary": outcome["summary"],
                "suggested_change": "Add a deploy-gate guardrail.",
                "source_path": "/tmp/SKILL.md",
            }
        ],
        "spans": 1,
        "by_entity": {"skill:workflow-orchestrator": 1},
    }

    memory = self_learn.apply_memory(report, logs)
    hints = self_learn.hints(logs, "skill:workflow-orchestrator")

    assert outcome["schema"] == self_learn.OUTCOME_SCHEMA
    entry = memory["entities"]["skill:workflow-orchestrator"]
    assert entry["severity"] == "high"
    assert "stale deploy instruction" in json.dumps(hints)
    assert os.path.exists(self_learn.experiments_path(logs))
    ledger = self_learn.experiment_ledger_path(logs)
    assert os.path.exists(ledger)
    ledger_text = open(ledger, encoding="utf-8").read()
    assert "experiment_id\tcandidate_id\ttarget" in ledger_text
    assert "precision_at_1\thit_at_k\tdoctor_ok" in ledger_text
    assert "\tbaseline\t\t\t1\t1\t1\t" in ledger_text


def test_apply_source_skips_vendored_by_default_and_writes_guardrail_block(tmp_path):
    local = tmp_path / "plugin" / "SKILL.md"
    vendored = tmp_path / "vendored" / "skill" / "SKILL.md"
    local.parent.mkdir(parents=True)
    vendored.parent.mkdir(parents=True)
    local.write_text("# Local\n", encoding="utf-8")
    vendored.write_text("# Vendored\n", encoding="utf-8")
    report = {
        "proposals": [
            {
                "target_type": "skill",
                "target_name": "local",
                "source_path": str(local),
                "summary": "Local skill missed a validation step.",
                "validation": "Run targeted tests.",
            },
            {
                "target_type": "skill",
                "target_name": "vendored",
                "source_path": str(vendored),
                "summary": "Vendored skill missed a validation step.",
                "validation": "Run targeted tests.",
            },
        ]
    }

    changed, originals = self_learn.apply_source(report)

    assert changed == [str(local)]
    assert str(local) in originals
    assert "legion-self-learn:start" in local.read_text(encoding="utf-8")
    assert "legion-self-learn:start" not in vendored.read_text(encoding="utf-8")
    self_learn.restore_sources(originals)
    assert local.read_text(encoding="utf-8") == "# Local\n"


def test_apply_source_updates_markdown_description_for_trigger_fix(tmp_path):
    skill = tmp_path / "plugin" / "SKILL.md"
    skill.parent.mkdir(parents=True)
    skill.write_text(
        "---\n"
        "name: local\n"
        'description: "Local workflow skill"\n'
        "---\n"
        "\n"
        "# Local\n",
        encoding="utf-8",
    )
    evidence = {
        "prompt": "Use local skill for release gate validation and scorecard experiments"
    }
    report = {
        "proposals": [
            {
                "id": "p1",
                "kind": "trigger_description_fix",
                "target_type": "skill",
                "target_name": "local",
                "source_path": str(skill),
                "summary": "Trigger eval missed local.",
                "evidence": json.dumps(evidence),
                "validation": "Run entity eval.",
            }
        ]
    }

    changed, originals = self_learn.apply_source(report)

    assert changed == [str(skill)]
    text = skill.read_text(encoding="utf-8")
    assert "Trigger hints:" in text
    assert "release" in text
    assert "legion-self-learn:start" not in text
    self_learn.restore_sources(originals)
    assert 'description: "Local workflow skill"' in skill.read_text(encoding="utf-8")


def test_apply_memory_preserves_existing_entity_hints(tmp_path):
    logs = str(tmp_path / "logs")
    existing = self_learn._empty_memory()
    existing["entities"]["command:review-gate"] = {
        "target_type": "command",
        "target_name": "review-gate",
        "severity": "medium",
        "hints": ["Existing guardrail"],
        "proposal_ids": ["old"],
        "source_paths": [],
    }
    self_learn._write_json(self_learn.memory_path(logs), existing)
    report = {
        "generated_at": "2026-06-19T00:00:00Z",
        "day": "2026-06-19",
        "outcomes": [],
        "proposals": [
            {
                "id": "new",
                "target_type": "skill",
                "target_name": "workflow-orchestrator",
                "severity": "low",
                "summary": "New hint",
                "suggested_change": "Add one check.",
                "source_path": "/tmp/SKILL.md",
            }
        ],
    }

    memory = self_learn.apply_memory(report, logs)

    assert "command:review-gate" in memory["entities"]
    assert memory["entities"]["command:review-gate"]["hints"] == ["Existing guardrail"]
    assert "skill:workflow-orchestrator" in memory["entities"]


def test_apply_memory_keeps_unresolved_outcomes_active(tmp_path, monkeypatch):
    repo = tmp_path / "repo"
    logs = str(tmp_path / "logs")
    repo.mkdir()
    monkeypatch.setattr(self_learn, "build_catalog", lambda _repo: _catalog(tmp_path))
    monkeypatch.setattr(self_learn, "trigger_eval_outcomes", lambda _repo, _catalog: [])
    monkeypatch.setattr(self_learn, "routing_outcomes", lambda _repo, _logs, _spans=None: [])
    monkeypatch.setattr(self_learn, "run_scorecard", lambda _repo: self_learn.empty_scorecard(str(repo)))
    outcome = {
        "schema": self_learn.OUTCOME_SCHEMA,
        "id": "processed-once",
        "ts": "2026-06-19T00:00:00Z",
        "source": "manual",
        "target_type": "command",
        "target_name": "feature",
        "severity": "medium",
        "summary": "Feature command repeated stale advice.",
        "evidence": "run-1",
        "run_id": "",
        "source_path": "",
        "metadata": {},
    }
    self_learn._append_jsonl(self_learn.outcomes_path(logs), outcome)

    first = self_learn.build_report(str(repo), logs, "2026-06-19")
    assert [item["id"] for item in first["outcomes"]] == ["processed-once"]
    memory = self_learn.apply_memory(first, logs)
    assert "processed-once" not in memory["processed_outcome_ids"]

    second = self_learn.build_report(str(repo), logs, "2026-06-19")
    assert [item["id"] for item in second["outcomes"]] == ["processed-once"]
    audit = self_learn.build_report(str(repo), logs, "2026-06-19", include_processed=True)
    assert [item["id"] for item in audit["outcomes"]] == ["processed-once"]


def test_apply_memory_marks_kept_candidate_outcomes_processed(tmp_path):
    logs = str(tmp_path / "logs")
    report = {
        "generated_at": "2026-06-19T00:00:00Z",
        "day": "2026-06-19",
        "outcomes": [
            {
                "id": "resolved-outcome",
                "target_type": "skill",
                "target_name": "workflow-orchestrator",
            }
        ],
        "proposals": [
            {
                "id": "proposal-1",
                "outcome_id": "resolved-outcome",
                "target_type": "skill",
                "target_name": "workflow-orchestrator",
                "summary": "Resolved by a kept source experiment.",
                "suggested_change": "Patch the trigger description.",
                "source_path": "/tmp/SKILL.md",
            }
        ],
        "experiments": {
            "status": "kept",
            "selected_candidate": "candidate-1",
            "candidates": [
                {
                    "id": "candidate-1",
                    "status": "keep",
                    "decision": "measured_improvement",
                    "proposal_ids": ["proposal-1"],
                }
            ],
        },
    }

    memory = self_learn.apply_memory(report, logs)

    assert memory["processed_outcome_ids"] == ["resolved-outcome"]


def _score(value, *, ok=True, pass_count=1, cases=1):
    return {
        "schema": self_learn.SCORECARD_SCHEMA,
        "generated_at": "2026-06-19T00:00:00Z",
        "ok": ok,
        "score": value,
        "metrics": {
            "cases": cases,
            "pass": pass_count,
            "collision": 0,
            "miss": cases - pass_count,
            "precision_at_1": value,
            "hit_at_k": value,
            "pass_rate": value,
        },
        "checks": [
            {"name": "legion-eval", "ok": ok, "summary": {"precision_at_1": value}},
            {"name": "legion-doctor", "ok": ok},
        ],
    }


def test_candidate_experiment_discards_non_improving_source_patch(tmp_path, monkeypatch):
    repo = tmp_path / "repo"
    source = repo / "plugin" / "SKILL.md"
    source.parent.mkdir(parents=True)
    source.write_text("# Skill\n", encoding="utf-8")
    report = {
        "repo": str(repo),
        "day": "2026-06-19",
        "spans": 0,
        "outcomes": [],
        "proposals": [
            {
                "id": "p1",
                "kind": "review_guardrail",
                "target_type": "skill",
                "target_name": "plugin",
                "source_path": str(source),
                "summary": "Add a guardrail.",
                "validation": "Run eval.",
            }
        ],
        "scorecard": _score(1.0),
    }
    monkeypatch.setattr(self_learn, "run_scorecard", lambda _repo: _score(1.0))

    result = self_learn.run_candidate_experiments(
        report,
        str(repo),
        max_candidates=2,
        max_workers=1,
        min_score_delta=0.001,
    )

    assert result["selected_candidate"] is None
    assert result["candidates"][0]["status"] == "discard"
    assert result["candidates"][0]["decision"] == "score_delta_below_min"
    assert source.read_text(encoding="utf-8") == "# Skill\n"


def test_candidate_experiment_skips_external_source_paths(tmp_path):
    repo = tmp_path / "repo"
    source = tmp_path / "outside" / "SKILL.md"
    repo.mkdir()
    source.parent.mkdir()
    source.write_text("# External\n", encoding="utf-8")
    report = {
        "repo": str(repo),
        "proposals": [
            {
                "id": "p1",
                "kind": "review_guardrail",
                "target_type": "skill",
                "target_name": "external",
                "source_path": str(source),
                "summary": "This must not mutate outside the repo.",
            }
        ],
        "scorecard": _score(1.0),
    }

    result = self_learn.run_candidate_experiments(report, str(repo), max_workers=1)

    assert result["status"] == "no_candidates"
    assert source.read_text(encoding="utf-8") == "# External\n"


def test_candidate_experiment_skips_symlink_source_paths(tmp_path):
    repo = tmp_path / "repo"
    source = repo / "plugin" / "SKILL.md"
    target = tmp_path / "outside" / "SKILL.md"
    source.parent.mkdir(parents=True)
    target.parent.mkdir()
    target.write_text("# External target\n", encoding="utf-8")
    os.symlink(target, source)
    report = {
        "repo": str(repo),
        "proposals": [
            {
                "id": "p1",
                "kind": "review_guardrail",
                "target_type": "skill",
                "target_name": "symlinked",
                "source_path": str(source),
                "summary": "This must not follow a symlink target.",
            }
        ],
        "scorecard": _score(1.0),
    }

    result = self_learn.run_candidate_experiments(report, str(repo), max_workers=1)

    assert result["status"] == "no_candidates"
    assert target.read_text(encoding="utf-8") == "# External target\n"


def test_candidate_experiment_keeps_measured_improvement(tmp_path, monkeypatch):
    repo = tmp_path / "repo"
    source = repo / "plugin" / "SKILL.md"
    source.parent.mkdir(parents=True)
    source.write_text("# Skill\n", encoding="utf-8")
    report = {
        "repo": str(repo),
        "day": "2026-06-19",
        "spans": 0,
        "outcomes": [],
        "proposals": [
            {
                "id": "p1",
                "kind": "review_guardrail",
                "target_type": "skill",
                "target_name": "plugin",
                "source_path": str(source),
                "summary": "Add a guardrail.",
                "validation": "Run eval.",
            }
        ],
        "scorecard": _score(0.5, pass_count=1, cases=2),
    }
    scores = [_score(0.8, pass_count=2, cases=2), _score(0.8, pass_count=2, cases=2)]
    monkeypatch.setattr(self_learn, "run_scorecard", lambda _repo: scores.pop(0))

    result = self_learn.run_candidate_experiments(
        report,
        str(repo),
        max_candidates=2,
        max_workers=1,
        min_score_delta=0.001,
    )

    assert result["selected_candidate"] == result["candidates"][0]["id"]
    assert result["candidates"][0]["status"] == "keep"
    assert result["changed_source"] == [str(source)]
    assert "legion-self-learn:start" in source.read_text(encoding="utf-8")


def test_candidate_experiment_rolls_back_when_final_scorecard_raises(tmp_path, monkeypatch):
    repo = tmp_path / "repo"
    source = repo / "plugin" / "SKILL.md"
    source.parent.mkdir(parents=True)
    source.write_text("# Skill\n", encoding="utf-8")
    report = {
        "repo": str(repo),
        "day": "2026-06-19",
        "spans": 0,
        "outcomes": [],
        "proposals": [
            {
                "id": "p1",
                "kind": "review_guardrail",
                "target_type": "skill",
                "target_name": "plugin",
                "source_path": str(source),
                "summary": "Add a guardrail.",
                "validation": "Run eval.",
            }
        ],
        "scorecard": _score(0.5, pass_count=1, cases=2),
    }
    calls = {"count": 0}

    def score_or_raise(_repo):
        calls["count"] += 1
        if calls["count"] == 1:
            return _score(0.8, pass_count=2, cases=2)
        raise RuntimeError("scorecard failed")

    monkeypatch.setattr(self_learn, "run_scorecard", score_or_raise)

    result = self_learn.run_candidate_experiments(
        report,
        str(repo),
        max_candidates=2,
        max_workers=1,
        min_score_delta=0.001,
    )

    assert result["status"] == "rolled_back"
    assert result["final_decision"]["decision"] == "exception"
    assert source.read_text(encoding="utf-8") == "# Skill\n"
