import datetime as dt
import hashlib
import importlib.util
import json
import os
import re
import stat
import threading
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
LEGION_RUN_PATH = ROOT / "legion-orchestrate" / "scripts" / "legion-run.py"


def load_legion_run():
    spec = importlib.util.spec_from_file_location("legion_run_integrity", LEGION_RUN_PATH)
    assert spec is not None
    module = importlib.util.module_from_spec(spec)
    assert spec.loader is not None
    spec.loader.exec_module(module)
    return module


def test_same_second_run_reservations_are_atomic_and_unique(tmp_path):
    legion_run = load_legion_run()
    fixed_now = dt.datetime(2026, 7, 31, 10, 25, 17, tzinfo=dt.timezone.utc)
    callers = 16
    ready = threading.Barrier(callers)

    def reserve():
        ready.wait()
        return legion_run.reserve_run_directory(
            tmp_path,
            "billing-export",
            now=fixed_now,
        )

    with ThreadPoolExecutor(max_workers=callers) as pool:
        reservations = list(pool.map(lambda _index: reserve(), range(callers)))

    run_ids = [run_id for run_id, _run_dir in reservations]
    run_dirs = [run_dir for _run_id, run_dir in reservations]
    legacy_id = "20260731T102517Z-billing-export"

    assert legacy_id in run_ids
    assert len(set(run_ids)) == callers
    assert len(set(run_dirs)) == callers
    assert all(path.is_dir() for path in run_dirs)
    assert all(path.name == run_id for run_id, path in reservations)
    assert all(
        re.fullmatch(
            r"20260731T102517Z-billing-export(?:-(?:[2-9]|[1-9][0-9]+))?",
            run_id,
        )
        for run_id in run_ids
    )


def test_run_directory_and_artifacts_are_private_under_permissive_umask(tmp_path):
    legion_run = load_legion_run()
    previous_umask = os.umask(0)
    try:
        _run_id, run_dir = legion_run.reserve_run_directory(
            tmp_path,
            "private-run",
            now=dt.datetime(2026, 7, 31, 10, 25, 17, tzinfo=dt.timezone.utc),
        )
        artifact = run_dir / "plan.json"
        legion_run._write_json(artifact, {"task": "sensitive"})
    finally:
        os.umask(previous_umask)

    runs_root = tmp_path / "runs" / "legion-run"
    assert stat.S_IMODE(runs_root.stat().st_mode) == 0o700
    assert stat.S_IMODE(run_dir.stat().st_mode) == 0o700
    assert stat.S_IMODE(artifact.stat().st_mode) == 0o600


def test_hermetic_stage_environment_drops_runner_state_overrides():
    legion_run = load_legion_run()
    env = {
        "HOME": "/safe-home",
        "LEGION_STATE_ROOT": "/outer/state",
        "LEGION_REGISTRY_DIR": "/outer/registry",
        "LEGION_PROJECT_LEARNING_DIR": "/outer/learning",
        "LEGION_GLOBAL_LEARNING_DIR": "/outer/global-learning",
        "LEGION_PROJECT_ID": "outer-project",
        "LEGION_TRACE_ID": "trace-kept",
    }

    clean = legion_run.hermetic_stage_env(env)

    assert clean["HOME"] == "/safe-home"
    assert clean["LEGION_TRACE_ID"] == "trace-kept"
    assert clean["LEGION_VALIDATION"] == "1"
    assert "LEGION_STATE_ROOT" not in clean
    assert "LEGION_REGISTRY_DIR" not in clean
    assert "LEGION_PROJECT_LEARNING_DIR" not in clean
    assert "LEGION_GLOBAL_LEARNING_DIR" not in clean
    assert "LEGION_PROJECT_ID" not in clean


def test_learning_context_rejects_forged_budget_and_token_accounting():
    legion_run = load_legion_run()
    guidance = "x" * 20_000
    payload = {
        "schema": "legion.learning-context.v1",
        "repository_identity": "repo-id",
        "entity": "heavy-task:billing",
        "stage": "plan",
        "limits": {"max_hints": 1_000_000, "max_tokens": 1_000_000},
        "usage": {
            "schema": "legion.learning-usage.v1",
            "hint_count": 1,
            "token_count": 0,
        },
        "selected_hints": [
            {
                "id": "forged",
                "scope": "global",
                "guidance": guidance,
                "selection_reason": "global",
                "token_count": 0,
            }
        ],
        "excluded_hints": [],
    }

    error = legion_run._learning_context_error(
        payload,
        repository_identity="repo-id",
        entity="heavy-task:billing",
        stage="plan",
    )

    assert "absolute caps" in error


def test_named_run_feedback_uses_the_same_entity_as_context_retrieval(tmp_path):
    legion_run = load_legion_run()
    runner = {
        "name": "fieldops",
        "target_type": "plugin",
        "learning_entity": "heavy-task:billing-export",
    }

    outcomes = legion_run.collect_learning_outcomes(
        runner=runner,
        run_id="run-1",
        run_dir=tmp_path,
        stage_payloads={
            "validate": {
                "learning_feedback": [
                    {
                        "summary": "Preserve the export idempotency boundary.",
                        "severity": "high",
                        "source": "manual",
                        "target_type": "skill",
                        "target_name": "attacker-selected",
                    }
                ]
            }
        },
        failed_stage="validate",
        failure_message="validator failed",
    )

    assert outcomes
    assert {
        (outcome["target_type"], outcome["target_name"])
        for outcome in outcomes
    } == {("heavy-task", "billing-export")}
    assert {outcome["source"] for outcome in outcomes} == {
        "legion-run:validate",
        "legion-run:terminal",
    }


def test_validator_feedback_metadata_is_allowlisted_and_bounded(tmp_path):
    legion_run = load_legion_run()
    metadata = {
        "stage": "forged",
        "artifact": "forged.json",
        "feedback_id": "forged-id",
        "a_nested": {"bounded": [1, 2, 3]},
        "oversized": "x" * 2_000,
        "bad key": "ignored",
        **{f"key-{index:02d}": index for index in range(40)},
    }

    outcomes = legion_run.collect_learning_outcomes(
        runner={
            "name": "fieldops",
            "target_type": "plugin",
            "learning_entity": "heavy-task:billing-export",
        },
        run_id="run-bounded-metadata",
        run_dir=tmp_path,
        stage_payloads={
            "validate": {
                "learning_feedback": [
                    {
                        "id": "validator-feedback",
                        "summary": "Keep validator metadata bounded.",
                        "metadata": metadata,
                    }
                ]
            }
        },
    )

    stored = outcomes[0]["metadata"]
    assert stored["stage"] == "validate"
    assert stored["artifact"] == "validation.json"
    assert stored["feedback_id"] == "validator-feedback"
    assert stored["a_nested"] == {"bounded": [1, 2, 3]}
    assert "oversized" not in stored
    assert "bad key" not in stored
    assert len(stored) <= 35
    assert len(json.dumps(stored, sort_keys=True).encode("utf-8")) < 4_500


def test_learning_receipt_id_and_manifest_bind_canonical_artifact_bytes(tmp_path):
    legion_run = load_legion_run()
    descriptor = {
        "path": str(tmp_path / "learning-context.json"),
        "revision": "a" * 64,
        "mode": "advisory",
        "dispositions": [],
    }
    receipts_path = tmp_path / "learning-receipts.json"
    legion_run._write_learning_receipts(
        receipts_path,
        descriptor=descriptor,
        descriptors={"plan": descriptor},
        receipts=[],
    )
    payload = json.loads(receipts_path.read_text(encoding="utf-8"))
    receipt_id = payload.pop("receipt_id")
    expected = hashlib.sha256(
        json.dumps(
            payload, sort_keys=True, separators=(",", ":"), ensure_ascii=True
        ).encode("utf-8")
    ).hexdigest()
    assert receipt_id == expected
    payload["receipts"].append({"status": "forged"})
    payload["receipt_id"] = receipt_id
    assert legion_run._learning_receipts_valid(payload) is False

    manifest = legion_run.write_artifact_manifest(tmp_path)
    entry = next(
        item for item in manifest["artifacts"] if item["path"] == "learning-receipts.json"
    )
    assert entry["sha256"] == hashlib.sha256(receipts_path.read_bytes()).hexdigest()
