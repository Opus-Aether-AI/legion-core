import argparse
import importlib.util
import json
import os
import subprocess


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


def test_default_repo_prefers_marketplace_root_override(tmp_path, monkeypatch):
    monkeypatch.setenv("MARKETPLACE_ROOT", str(tmp_path / "marketplace"))
    monkeypatch.setenv("LEGION_ROOT", str(tmp_path / "other"))
    assert self_learn.default_repo() == os.path.abspath(str(tmp_path / "marketplace"))


def test_default_repo_walks_up_to_repo_marketplace(monkeypatch):
    # With no override, the default walks up to the nearest marketplace root.
    monkeypatch.delenv("LEGION_ROOT", raising=False)
    monkeypatch.delenv("LEGION_MARKETPLACE_ROOT", raising=False)
    monkeypatch.delenv("MARKETPLACE_ROOT", raising=False)
    repo_root = os.path.abspath(os.path.join(HERE, "..", ".."))
    assert self_learn.default_repo() == repo_root


def test_default_repo_walks_up_from_vendored_layout(tmp_path, monkeypatch):
    consumer = tmp_path / "consumer"
    scripts = consumer / "vendored" / "legion-core" / "legion-observability" / "scripts"
    (consumer / ".claude-plugin").mkdir(parents=True)
    (consumer / ".claude-plugin" / "marketplace.json").write_text("{}", encoding="utf-8")
    scripts.mkdir(parents=True)
    monkeypatch.delenv("LEGION_ROOT", raising=False)
    monkeypatch.delenv("LEGION_MARKETPLACE_ROOT", raising=False)
    monkeypatch.delenv("MARKETPLACE_ROOT", raising=False)
    monkeypatch.setattr(self_learn, "_here", lambda: str(scripts))

    assert self_learn.default_repo() == os.path.abspath(str(consumer))


def test_default_repo_prefers_active_git_worktree_over_outer_consumer(tmp_path, monkeypatch):
    consumer = tmp_path / "consumer"
    worktree = consumer / ".legion" / "worktrees" / "review"
    scripts = worktree / "legion-observability" / "scripts"
    for root in (consumer, worktree):
        (root / ".claude-plugin").mkdir(parents=True)
        (root / ".claude-plugin" / "marketplace.json").write_text("{}", encoding="utf-8")
    scripts.mkdir(parents=True)
    subprocess.run(["git", "-C", str(worktree), "init", "-q"], check=True)
    monkeypatch.delenv("LEGION_ROOT", raising=False)
    monkeypatch.delenv("LEGION_MARKETPLACE_ROOT", raising=False)
    monkeypatch.delenv("MARKETPLACE_ROOT", raising=False)
    monkeypatch.setattr(self_learn, "_here", lambda: str(scripts))

    assert self_learn.default_repo() == os.path.abspath(str(worktree))


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
            "model": "test-model-beta",
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
            "model": "test-model-alpha",
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
        "model": "test-model-beta",
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
        "model": "test-model-beta",
        "task": "/feature passed today",
        "target_type": "command",
        "target_name": "feature",
    }
    (spans / "2026-06-18.jsonl").write_text(json.dumps(old) + "\n", encoding="utf-8")
    (spans / "2026-06-19.jsonl").write_text(json.dumps(new) + "\n", encoding="utf-8")
    monkeypatch.setattr(self_learn, "build_catalog", lambda _repo: _catalog(tmp_path))
    monkeypatch.setattr(self_learn, "trigger_eval_outcomes", lambda _repo, _catalog: [])
    monkeypatch.setattr(self_learn, "routing_outcomes", lambda _repo, _logs, _spans=None: [])
    monkeypatch.setattr(self_learn, "learning_law_outcomes", lambda _repo: [])

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


def test_default_cli_state_honors_resolved_telemetry_directory(
    tmp_path, monkeypatch, capsys
):
    repo = tmp_path / "repo"
    state_root = tmp_path / "state"
    telemetry = tmp_path / "custom-telemetry"
    repo.mkdir()
    telemetry.mkdir()
    (telemetry / "2026-08-07.jsonl").write_text(
        json.dumps(
            {
                "schema": "legion.span.v1",
                "run_id": "telemetry-run",
                "executor": "codex",
                "model": "test-model",
                "status": "ok",
            }
        )
        + "\n",
        encoding="utf-8",
    )
    monkeypatch.setattr(
        self_learn.legion_state,
        "resolve_state",
        lambda _repo: {
            "state_root": str(state_root),
            "telemetry_dir": str(telemetry),
        },
    )
    monkeypatch.setattr(self_learn, "build_catalog", lambda _repo: _catalog(tmp_path))
    monkeypatch.setattr(self_learn, "trigger_eval_outcomes", lambda _repo, _catalog: [])
    monkeypatch.setattr(
        self_learn, "routing_outcomes", lambda _repo, _logs, _spans=None: []
    )
    monkeypatch.setattr(self_learn, "learning_law_outcomes", lambda _repo: [])
    monkeypatch.setattr(
        self_learn,
        "run_scorecard",
        lambda _repo: self_learn.empty_scorecard(str(repo)),
    )

    result = self_learn.main(
        ["run", "--repo", str(repo), "--day", "2026-08-07", "--json"]
    )

    assert result == 0
    payload = json.loads(capsys.readouterr().out)
    report = json.loads(
        open(payload["report_path"], encoding="utf-8").read()
    )
    assert report["spans"] == 1


def test_build_report_turns_promoted_learning_laws_into_proposals(tmp_path, monkeypatch):
    repo = tmp_path / "repo"
    logs = tmp_path / "logs"
    learning = tmp_path / "global-learning"
    repo.mkdir()
    learning.mkdir()
    (learning / "laws.json").write_text(
        json.dumps(
            {
                "schema": "legion.learning-laws.v1",
                "laws": [
                    {
                        "schema": "legion.learning-law.v1",
                        "key": "test-real-workflow",
                        "status": "active",
                        "confidence": 0.91,
                        "support": {"episodes": 5, "projects": 3},
                        "evidence_ids": ["d1", "d2", "d3"],
                        "guidance": "Validate the real user workflow before changing its docs or UI.",
                        "validation": "Run a representative end-to-end workflow.",
                    }
                ],
            }
        ),
        encoding="utf-8",
    )
    monkeypatch.setenv("LEGION_GLOBAL_LEARNING_DIR", str(learning))
    monkeypatch.setattr(self_learn, "build_catalog", lambda _repo: _catalog(tmp_path))
    monkeypatch.setattr(self_learn, "trigger_eval_outcomes", lambda _repo, _catalog: [])
    monkeypatch.setattr(self_learn, "routing_outcomes", lambda _repo, _logs, _spans=None: [])
    monkeypatch.setattr(self_learn, "run_scorecard", lambda _repo: self_learn.empty_scorecard(str(repo)))

    report = self_learn.build_report(str(repo), str(logs), "2026-08-05")

    assert report["outcomes"][0]["source"] == "learning-law"
    assert report["outcomes"][0]["metadata"]["law_key"] == "test-real-workflow"
    assert report["proposals"][0]["kind"] == "learned_behavior_guardrail"
    assert "end-to-end" in report["proposals"][0]["validation"]


def test_learning_law_proposal_id_is_stable_across_revisions(tmp_path):
    original = {
        "id": "outcome-v1",
        "source": "learning-law",
        "target_type": "plugin",
        "target_name": "legion-observability",
        "severity": "medium",
        "summary": "Promoted learning law 'test-real-workflow' from 3 episodes.",
        "evidence": "first evidence set",
        "metadata": {
            "law_key": "test-real-workflow",
            "guidance": "Validate the representative workflow.",
            "validation": "Run the workflow once.",
        },
    }
    revised = {
        **original,
        "id": "outcome-v2",
        "severity": "high",
        "summary": "Promoted learning law 'test-real-workflow' from 8 episodes.",
        "evidence": "expanded evidence set",
        "metadata": {
            **original["metadata"],
            "guidance": "Validate the complete live workflow.",
        },
    }

    first = self_learn.proposal_for_outcome(original, _catalog(tmp_path))
    second = self_learn.proposal_for_outcome(revised, _catalog(tmp_path))

    assert first["id"] == second["id"]


def test_supported_learning_law_emits_bounded_typed_improvement_queue(tmp_path):
    repo = tmp_path / "repo"
    plugin = repo / "legion-observability"
    logs = tmp_path / "logs"
    plugin.mkdir(parents=True)
    (plugin / "SKILL.md").write_text("# Observability\n", encoding="utf-8")
    outcome = {
        "id": "law-outcome",
        "source": "learning-law",
        "summary": "Promoted a reliable workflow law.",
        "evidence": json.dumps({"evidence_ids": ["e1", "e2", "e3"]}),
        "metadata": {
            "law_key": "real-workflow",
            "confidence": 0.93,
            "support": {"episodes": 7, "projects": 4},
            "guidance": "Validate the real user workflow before declaring success.",
        },
    }
    legacy = {
        "id": "legacy-proposal",
        "summary": outcome["summary"],
        "source_path": str(plugin),
    }

    typed = self_learn.typed_improvement_proposal(outcome, legacy, str(repo))

    assert typed["schema"] == "legion.improvement-proposal.v1"
    assert typed["revision"] == 7
    assert typed["target"] == {"path": "legion-observability/SKILL.md"}
    assert typed["candidate"]["operation"] == "append_markdown_guardrail"
    assert "command" not in typed["candidate"]
    paths = self_learn.write_improvement_queue(
        {"improvement_proposals": [typed]}, str(logs)
    )
    assert len(paths) == 1
    queued = json.loads(open(paths[0], encoding="utf-8").read())
    assert queued == typed
    assert str(repo) not in json.dumps(queued, sort_keys=True)


def test_weak_or_single_project_learning_never_enters_improvement_queue(tmp_path):
    repo = tmp_path / "repo"
    repo.mkdir()
    target = repo / "SKILL.md"
    target.write_text("# Skill\n", encoding="utf-8")
    outcome = {
        "source": "learning-law",
        "summary": "Weak law.",
        "evidence": "{}",
        "metadata": {
            "law_key": "weak",
            "confidence": 0.99,
            "support": {"episodes": 20, "projects": 1},
            "guidance": "Do a thing.",
        },
    }
    legacy = {"id": "weak", "summary": "Weak law.", "source_path": str(target)}

    assert self_learn.typed_improvement_proposal(outcome, legacy, str(repo)) is None


def test_over_budget_span_becomes_learning_outcome(tmp_path):
    catalog = _catalog(tmp_path)
    spans = [
        {
            "schema": "legion.span.v1",
            "run_id": "run-budget",
            "status": "over_budget",
            "executor": "codex",
            "model": "test-model-beta",
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


def test_apply_memory_replaces_legacy_law_hint_and_renders_revision_first(tmp_path):
    logs = str(tmp_path / "logs")
    existing = self_learn._empty_memory()
    existing["entities"]["plugin:legion-observability"] = {
        "target_type": "plugin",
        "target_name": "legion-observability",
        "severity": "medium",
        "hints": [
            (
                "Promoted learning law 'test-real-workflow' from 3 episodes. "
                "Suggested: Validate the representative workflow."
            ),
            "Existing hint two.",
            "Existing hint three.",
            "Existing hint four.",
            "Existing hint five.",
        ],
        "proposal_ids": ["legacy-law-proposal"],
        "source_paths": [],
    }
    self_learn._write_json(self_learn.memory_path(logs), existing)
    revised_outcome = {
        "id": "revised-law-outcome",
        "source": "learning-law",
        "target_type": "plugin",
        "target_name": "legion-observability",
        "severity": "high",
        "summary": "Promoted learning law 'test-real-workflow' from 8 episodes.",
        "evidence": "expanded evidence set",
        "metadata": {
            "law_key": "test-real-workflow",
            "guidance": "Validate the complete live workflow.",
            "validation": "Run the complete workflow.",
        },
    }
    proposal = self_learn.proposal_for_outcome(revised_outcome, _catalog(tmp_path))
    report = {
        "generated_at": "2026-08-05T00:00:00Z",
        "day": "2026-08-05",
        "outcomes": [revised_outcome],
        "proposals": [proposal],
    }

    memory = self_learn.apply_memory(report, logs)
    rendered = self_learn.render_hints(
        self_learn.hints(logs, "plugin:legion-observability")
    )

    stored_hints = memory["entities"]["plugin:legion-observability"]["hints"]
    assert all("Validate the representative workflow." not in hint for hint in stored_hints)
    assert "Validate the complete live workflow." in rendered
    assert "Validate the representative workflow." not in rendered


def test_apply_memory_keeps_unresolved_outcomes_active(tmp_path, monkeypatch):
    repo = tmp_path / "repo"
    logs = str(tmp_path / "logs")
    repo.mkdir()
    monkeypatch.setattr(self_learn, "build_catalog", lambda _repo: _catalog(tmp_path))
    monkeypatch.setattr(self_learn, "trigger_eval_outcomes", lambda _repo, _catalog: [])
    monkeypatch.setattr(self_learn, "routing_outcomes", lambda _repo, _logs, _spans=None: [])
    monkeypatch.setattr(self_learn, "run_scorecard", lambda _repo: self_learn.empty_scorecard(str(repo)))
    monkeypatch.setattr(self_learn, "learning_law_outcomes", lambda _repo: [])
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


def test_scorecards_omit_unmeasured_cost_and_token_metrics():
    repo = os.path.abspath(os.path.join(HERE, "..", ".."))
    scorecards = [
        self_learn.empty_scorecard(repo, reason="unavailable"),
        self_learn.run_scorecard(repo),
    ]

    for scorecard in scorecards:
        assert "cost_usd" not in scorecard["metrics"]
        assert "tokens" not in scorecard["metrics"]


def test_compare_scorecards_rejects_negative_metric_regression():
    baseline = _score(0.5, pass_count=1, cases=2)
    candidate = _score(0.8, pass_count=2, cases=2)
    baseline["metrics"].update({"cost_usd": 0.1, "tokens": 100, "safety_regressions": 0})
    candidate["metrics"].update({"cost_usd": 0.1, "tokens": 100, "safety_regressions": 1})

    result = self_learn.compare_scorecards(baseline, candidate)

    assert result["status"] == "discard"
    assert result["decision"] == "metric_regression"
    assert "safety_regressions" in result["regressions"]


def test_compare_scorecards_ignores_unmeasured_cost_and_token_fields():
    baseline = _score(0.5, pass_count=1, cases=2)
    candidate = _score(1.0, pass_count=2, cases=2)
    baseline["metrics"].update({"cost_usd": 0.1, "tokens": 100})
    candidate["metrics"].update({"cost_usd": 5.0, "tokens": 5000})

    result = self_learn.compare_scorecards(baseline, candidate)

    assert result == {
        "status": "keep",
        "decision": "measured_improvement",
        "delta": 0.5,
        "regressions": [],
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
