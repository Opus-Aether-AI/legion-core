import importlib.util
import json
import os
from pathlib import Path

import pytest


ROOT = Path(__file__).resolve().parents[2]
LEGION_RUN_PATH = ROOT / "legion-orchestrate" / "scripts" / "legion-run.py"


def load_legion_run():
    spec = importlib.util.spec_from_file_location("legion_run", LEGION_RUN_PATH)
    assert spec is not None
    module = importlib.util.module_from_spec(spec)
    assert spec.loader is not None
    spec.loader.exec_module(module)
    return module


def runner():
    return {
        "name": "billing-export",
        "mode": "direct",
        "target_type": "heavy-task",
        "kind": "heavy-task",
        "pipeline": {"profile": "legion.heavy_task.v1"},
    }


def write_json(path: Path, payload):
    path.write_text(json.dumps(payload), encoding="utf-8")


def test_validate_stage_payload_rejects_fanout_semantic_failure(tmp_path):
    legion_run = load_legion_run()

    with pytest.raises(legion_run.LegionRunError) as exc:
        legion_run.validate_stage_payload(
            "fanout-apply",
            {"ok": 1, "failed": 1, "apply_conflicts": 0, "exit_code": 0},
            tmp_path / "fanout.json",
        )

    assert exc.value.code == 1
    assert "semantic failure" in str(exc.value)


def test_validate_stage_payload_rejects_review_findings(tmp_path):
    legion_run = load_legion_run()

    with pytest.raises(legion_run.LegionRunError) as structured_exc:
        legion_run.validate_stage_payload(
            "review",
            {
                "status": "ok",
                "verdict": {
                    "verdict": "request_changes",
                    "summary": "Cold-chain outages are under-escalated.",
                    "findings": [{"severity": "high", "title": "Include all cold-chain assets"}],
                },
            },
            tmp_path / "review.json",
        )

    with pytest.raises(legion_run.LegionRunError) as text_exc:
        legion_run.validate_stage_payload(
            "review",
            {
                "status": "ok",
                "verdict": "Full review comments:\n\n- [P1] Include all cold-chain assets in outage escalation",
            },
            tmp_path / "review.json",
        )

    assert "review requested changes" in str(structured_exc.value)
    assert "review requested changes" in str(text_exc.value)


def test_collect_learning_outcomes_harvests_doctor_and_validator_feedback(tmp_path):
    legion_run = load_legion_run()
    write_json(
        tmp_path / "doctor.json",
        [
            {
                "check": "skill-frontmatter",
                "severity": "fail",
                "entity": "skill:caveman",
                "message": "Description format broke line-based readers.",
            }
        ],
    )
    write_json(
        tmp_path / "validation.json",
        {
            "ok": False,
            "learning_feedback": [
                {
                    "source": "validation-feedback",
                    "target_type": "skill",
                    "target_name": "legion-run",
                    "severity": "high",
                    "summary": "Validation found a missing idempotency contract.",
                }
            ],
        },
    )

    outcomes = legion_run.collect_learning_outcomes(
        runner=runner(),
        run_id="run-1",
        run_dir=tmp_path,
        failed_stage="validate",
        failure_message="validation failed",
    )

    identities = {(item["source"], item["target_type"], item["target_name"]) for item in outcomes}
    assert ("legion-run:doctor", "skill", "caveman") in identities
    assert ("validation-feedback", "skill", "legion-run") in identities
    assert ("legion-run:terminal", "heavy-task", "billing-export") in identities


def test_record_learning_feedback_writes_artifact_and_outcomes_jsonl(tmp_path):
    legion_run = load_legion_run()
    state_root = tmp_path / "state"
    run_dir = tmp_path / "run"
    run_dir.mkdir()
    write_json(
        run_dir / "fanout.json",
        {
            "ok": 1,
            "failed": 1,
            "apply_conflicts": 0,
            "results": [{"id": "green-core", "status": "failed", "error": "tests failed"}],
        },
    )

    payload = legion_run.record_learning_feedback(
        runner=runner(),
        run_id="run-2",
        run_dir=run_dir,
        env={"LEGION_STATE_ROOT": str(state_root), **os.environ},
        failed_stage="fanout-apply",
        failure_message="stage semantic failure",
    )

    assert payload["recorded"] == 2
    assert (run_dir / "learning-feedback.json").exists()
    outcomes_path = state_root / "self-learn" / "outcomes.jsonl"
    rows = [json.loads(line) for line in outcomes_path.read_text(encoding="utf-8").splitlines()]
    assert {row["source"] for row in rows} == {"legion-run:fanout-apply", "legion-run:terminal"}
