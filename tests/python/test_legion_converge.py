import importlib.util
import json
import os
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
PATH = ROOT / "legion-observability" / "scripts" / "legion-converge.py"


def load_module():
    spec = importlib.util.spec_from_file_location("legion_converge", PATH)
    assert spec is not None
    module = importlib.util.module_from_spec(spec)
    assert spec.loader is not None
    spec.loader.exec_module(module)
    return module


def checkpoint(*, source="tree-a", checks=None, review=None):
    return {
        "schema": "legion.convergence-checkpoint.v1",
        "task_id": "session-runtime-guard",
        "source_fingerprint": source,
        "checks": checks
        or [
            {
                "id": "tests",
                "scope": "local",
                "status": "passed",
                "evidence_fingerprint": "tests-green-a",
            }
        ],
        "review": review
        or {
            "head_sha": "a" * 40,
            "source_fingerprint": source,
            "blocking_findings": [],
            "suggestions": [],
        },
    }


def test_complete_ignores_non_blocking_review_suggestions():
    converge = load_module()
    payload = checkpoint(
        review={
            "head_sha": "a" * 40,
            "source_fingerprint": "tree-a",
            "blocking_findings": [],
            "suggestions": [{"fingerprint": "rename-helper"}],
        }
    )

    decision = converge.evaluate_checkpoint(payload)

    assert decision["state"] == "complete"
    assert decision["action"] == "yield"
    assert decision["suggestion_count"] == 1


def test_external_only_pending_yields_without_polling():
    converge = load_module()
    payload = checkpoint(
        checks=[
            {
                "id": "tests",
                "scope": "local",
                "status": "passed",
                "evidence_fingerprint": "tests-green-a",
            },
            {
                "id": "ci/installer",
                "scope": "external",
                "status": "pending",
                "evidence_fingerprint": "github-pending-31583861276",
            },
        ]
    )

    decision = converge.evaluate_checkpoint(payload)

    assert decision["state"] == "waiting_external"
    assert decision["action"] == "yield"
    assert decision["pending_external"] == ["ci/installer"]


def test_same_source_and_failure_fingerprint_blocks_a_repeat(tmp_path):
    converge = load_module()
    payload = checkpoint(
        checks=[
            {
                "id": "tests",
                "scope": "local",
                "status": "failed",
                "evidence_fingerprint": "failure-42",
            }
        ]
    )

    first = converge.checkpoint(payload, state_root=tmp_path)
    second = converge.checkpoint(payload, state_root=tmp_path)
    changed = converge.checkpoint(
        checkpoint(
            source="tree-b",
            checks=[
                {
                    "id": "tests",
                    "scope": "local",
                    "status": "failed",
                    "evidence_fingerprint": "failure-42",
                }
            ],
        ),
        state_root=tmp_path,
    )

    assert first["state"] == "actionable"
    assert first["action"] == "continue"
    assert second["state"] == "blocked"
    assert second["reason"] == "no_progress"
    assert changed["state"] == "actionable"


def test_changed_failure_evidence_is_actionable_on_same_source(tmp_path):
    converge = load_module()
    first = checkpoint(
        checks=[
            {
                "id": "tests",
                "scope": "local",
                "status": "failed",
                "evidence_fingerprint": "failure-a",
            }
        ]
    )
    second = checkpoint(
        checks=[
            {
                "id": "tests",
                "scope": "local",
                "status": "failed",
                "evidence_fingerprint": "failure-b",
            }
        ]
    )

    converge.checkpoint(first, state_root=tmp_path)
    decision = converge.checkpoint(second, state_root=tmp_path)

    assert decision["state"] == "actionable"
    assert decision["reason"] == "new_failure_evidence"


def test_blocking_review_finding_requires_immutable_head():
    converge = load_module()
    payload = checkpoint(
        review={
            "head_sha": "",
            "source_fingerprint": "tree-a",
            "blocking_findings": [{"fingerprint": "unsafe-cleanup"}],
            "suggestions": [],
        }
    )

    try:
        converge.evaluate_checkpoint(payload)
    except converge.ConvergenceError as error:
        assert "head_sha" in str(error)
    else:
        raise AssertionError("checkpoint unexpectedly accepted an unpinned review")


def test_checkpoint_rejects_missing_review_evidence():
    converge = load_module()
    missing_review = checkpoint()
    del missing_review["review"]
    missing_findings = checkpoint()
    del missing_findings["review"]["blocking_findings"]
    mismatched_source = checkpoint()
    mismatched_source["review"]["source_fingerprint"] = "tree-b"

    for payload in (missing_review, missing_findings, mismatched_source):
        try:
            converge.evaluate_checkpoint(payload)
        except converge.ConvergenceError as error:
            assert "review" in str(error)
        else:
            raise AssertionError("checkpoint accepted missing review evidence")


def test_recorded_history_is_privacy_safe(tmp_path):
    converge = load_module()
    payload = checkpoint(
        checks=[
            {
                "id": "private-customer-check",
                "scope": "local",
                "status": "passed",
                "evidence_fingerprint": "tests-green-a",
            }
        ]
    )
    payload["task_id"] = "customer secret project"

    decision = converge.checkpoint(payload, state_root=tmp_path)
    history = list((tmp_path / "convergence").glob("*.jsonl"))
    rendered = history[0].read_text(encoding="utf-8")

    assert decision["state"] == "complete"
    assert len(history) == 1
    assert "customer secret project" not in rendered
    assert "private-customer-check" not in rendered
    assert json.loads(rendered)["schema"] == "legion.convergence-decision.v1"
    assert oct(os.stat(history[0]).st_mode & 0o777) == "0o600"


def test_checkpoint_refuses_a_symlinked_history_file(tmp_path):
    converge = load_module()
    state_root = tmp_path / "state"
    convergence = state_root / "convergence"
    convergence.mkdir(parents=True)
    outside = tmp_path / "outside.jsonl"
    outside.write_text("sentinel\n", encoding="utf-8")
    history = convergence / f"{converge._digest('session-runtime-guard')}.jsonl"
    history.symlink_to(outside)

    try:
        converge.checkpoint(checkpoint(), state_root=state_root)
    except converge.ConvergenceError as error:
        assert "journal" in str(error)
    else:
        raise AssertionError("checkpoint followed a symlinked journal")

    assert outside.read_text(encoding="utf-8") == "sentinel\n"


def test_checkpoint_blocks_non_adjacent_repeated_evidence(tmp_path):
    converge = load_module()

    def failed(evidence):
        return checkpoint(
            checks=[
                {
                    "id": "tests",
                    "scope": "local",
                    "status": "failed",
                    "evidence_fingerprint": evidence,
                }
            ]
        )

    assert converge.checkpoint(failed("failure-a"), state_root=tmp_path)["state"] == "actionable"
    assert converge.checkpoint(failed("failure-b"), state_root=tmp_path)["state"] == "actionable"
    repeated = converge.checkpoint(failed("failure-a"), state_root=tmp_path)

    assert repeated["state"] == "blocked"
    assert repeated["reason"] == "no_progress"


def test_checkpoint_refuses_a_symlinked_state_root(tmp_path):
    converge = load_module()
    outside = tmp_path / "outside"
    outside.mkdir()
    state_root = tmp_path / "state"
    state_root.symlink_to(outside, target_is_directory=True)

    try:
        converge.checkpoint(checkpoint(), state_root=state_root)
    except converge.ConvergenceError as error:
        assert "state root" in str(error)
    else:
        raise AssertionError("checkpoint followed a symlinked state root")

    assert list(outside.iterdir()) == []


def test_checkpoint_bounds_identifiers_and_corrupt_history(tmp_path):
    converge = load_module()
    oversized = checkpoint()
    oversized["checks"][0]["id"] = "x" * 257
    try:
        converge.evaluate_checkpoint(oversized)
    except converge.ConvergenceError as error:
        assert "256-character limit" in str(error)
    else:
        raise AssertionError("checkpoint accepted an oversized check id")

    convergence = tmp_path / "convergence"
    convergence.mkdir()
    history = convergence / f"{converge._digest('session-runtime-guard')}.jsonl"
    history.write_text("not-json\n", encoding="utf-8")
    try:
        converge.checkpoint(checkpoint(), state_root=tmp_path)
    except converge.ConvergenceError as error:
        assert "latest convergence journal decision is malformed" in str(error)
    else:
        raise AssertionError("checkpoint ignored a corrupt nonempty journal")


def test_checkpoint_rejects_a_corrupt_latest_history_entry(tmp_path):
    converge = load_module()
    converge.checkpoint(checkpoint(), state_root=tmp_path)
    history = next((tmp_path / "convergence").glob("*.jsonl"))
    with history.open("a", encoding="utf-8") as stream:
        stream.write("{truncated\n")

    try:
        converge.checkpoint(checkpoint(), state_root=tmp_path)
    except converge.ConvergenceError as error:
        assert "latest convergence journal decision is malformed" in str(error)
    else:
        raise AssertionError("checkpoint ignored a corrupt latest journal entry")
