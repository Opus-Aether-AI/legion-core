import importlib
from pathlib import Path
import sys

import pytest


ROOT = Path(__file__).parents[2]
sys.path.insert(0, str(ROOT / "legion-observability" / "scripts"))
receipts = importlib.import_module("legion_receipts")


def attempt_fields(*, attempt_id, terminal_status="succeeded", failure=None, parent_attempt_id=None):
    return {
        "run_id": "run-1",
        "attempt_id": attempt_id,
        "ordinal": 1,
        "executor": "fixture",
        "provider": "fixture",
        "config_identity": "sha256:fixture",
        "requested_model": None,
        "effective_model": None,
        "requested_effort": None,
        "effective_effort": None,
        "sandbox": "read-only",
        "terminal_status": terminal_status,
        "started_at": "2026-09-10T00:00:00Z",
        "ended_at": "2026-09-10T00:00:01Z",
        "duration_ms": 1000,
        "failure": failure,
        "output_started": False,
        "parent_attempt_id": parent_attempt_id,
    }


def typed_failure(attempt_id):
    return receipts.failure_receipt(
        run_id="run-1",
        attempt_id=attempt_id,
        failure_class="provider",
        retryable=False,
        output_started=False,
    )


def test_constructor_rejects_failure_on_succeeded_attempt():
    with pytest.raises(ValueError, match="successful attempts cannot contain a typed failure"):
        receipts.attempt_receipt(
            **attempt_fields(
                attempt_id="attempt-1",
                terminal_status="succeeded",
                failure=typed_failure("attempt-1"),
            )
        )


def test_validator_rejects_schema_shaped_failure_on_succeeded_provider_attempt():
    attempt = receipts.attempt_receipt(
        **attempt_fields(
            attempt_id="attempt-1",
            terminal_status="failed",
            failure=typed_failure("attempt-1"),
        )
    )
    attempt["terminal_status"] = "succeeded"

    with pytest.raises(ValueError, match="successful attempts cannot contain a typed failure"):
        receipts.validate_attempt(attempt)


def test_validator_rejects_failure_on_succeeded_aggregate_before_early_return():
    child = receipts.attempt_receipt(
        **attempt_fields(attempt_id="child-1", parent_attempt_id="parent-1")
    )
    parent = receipts.aggregate_attempt_receipt(
        child_attempts=[child],
        **attempt_fields(
            attempt_id="parent-1",
            terminal_status="failed",
            failure=typed_failure("parent-1"),
        ),
    )
    parent["terminal_status"] = "succeeded"

    with pytest.raises(ValueError, match="successful attempts cannot contain a typed failure"):
        receipts.validate_attempt(parent)
