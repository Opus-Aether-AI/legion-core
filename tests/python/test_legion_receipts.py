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


@pytest.mark.parametrize("field", ["failure_id", "ts"])
@pytest.mark.parametrize("value", [0, 1, False, True, [], {}, ""])
def test_failure_constructor_rejects_supplied_non_string_identity(field, value):
    kwargs = {
        "run_id": "run-1",
        "attempt_id": "attempt-1",
        "failure_class": "provider",
        "retryable": False,
        "output_started": False,
        field: value,
    }

    with pytest.raises(ValueError, match=rf"{field} must be a non-empty string"):
        receipts.failure_receipt(**kwargs)


@pytest.mark.parametrize("field", ["failure_id", "ts"])
@pytest.mark.parametrize("value", [0, 1, False, True, [], {}, ""])
def test_failure_validator_rejects_non_string_identity(field, value):
    failure = typed_failure("attempt-1")
    failure[field] = value

    with pytest.raises(ValueError, match=rf"{field} must be a non-empty string"):
        receipts.validate_failure(failure)


@pytest.mark.parametrize("duration", [float("nan"), float("inf"), float("-inf")])
def test_attempt_constructor_and_validator_reject_non_finite_duration(duration):
    fields = attempt_fields(attempt_id="attempt-1")
    fields["duration_ms"] = duration
    with pytest.raises(ValueError, match="duration_ms must be a finite non-negative number"):
        receipts.attempt_receipt(**fields)

    attempt = receipts.attempt_receipt(**attempt_fields(attempt_id="attempt-1"))
    attempt["duration_ms"] = duration
    with pytest.raises(ValueError, match="duration_ms must be a finite non-negative number"):
        receipts.validate_attempt(attempt)


def test_cost_validator_rejects_unrepresentable_integer_without_overflowing():
    fields = attempt_fields(attempt_id="attempt-1")
    fields.update(cost_usd=10 ** 1000, cost_status="known", cost_source="provider-json")
    with pytest.raises(ValueError, match="cost_usd must be a finite non-negative number"):
        receipts.attempt_receipt(**fields)

    attempt = receipts.attempt_receipt(**attempt_fields(attempt_id="attempt-1"))
    attempt.update(cost_usd=10 ** 1000, cost_status="known", cost_source="provider-json")
    with pytest.raises(ValueError, match="cost_usd must be a finite non-negative number"):
        receipts.validate_attempt(attempt)


@pytest.mark.parametrize("attempt_id", ["", 0, 1, False, True, [], {}])
def test_attempt_constructor_rejects_explicit_invalid_attempt_id(attempt_id):
    with pytest.raises(ValueError, match="attempt_id must be a non-empty string"):
        receipts.attempt_receipt(**attempt_fields(attempt_id=attempt_id))


@pytest.mark.parametrize("attempt_id", ["", 0, 1, False, True, [], {}])
def test_attempt_validator_rejects_invalid_attempt_id(attempt_id):
    attempt = receipts.attempt_receipt(**attempt_fields(attempt_id="attempt-1"))
    attempt["attempt_id"] = attempt_id

    with pytest.raises(ValueError, match="attempt_id must be a non-empty string"):
        receipts.validate_attempt(attempt)


def test_attempt_constructor_does_not_replace_falsey_explicit_id_from_failure():
    with pytest.raises(ValueError, match="attempt_id must be a non-empty string"):
        receipts.attempt_receipt(
            **attempt_fields(
                attempt_id="",
                terminal_status="failed",
                failure=typed_failure("attempt-from-failure"),
            )
        )


def partial_aggregate():
    parent_id = "parent-1"
    known = receipts.attempt_receipt(
        **attempt_fields(attempt_id="child-1", parent_attempt_id=parent_id),
        usage={"input_tokens": 2},
        usage_status="known",
        usage_source="provider-json",
        cost_usd=0.25,
        cost_status="known",
        cost_source="provider-json",
    )
    unknown_fields = attempt_fields(attempt_id="child-2", parent_attempt_id=parent_id)
    unknown_fields["ordinal"] = 2
    unknown = receipts.attempt_receipt(**unknown_fields)
    return receipts.aggregate_attempt_receipt(
        child_attempts=[known, unknown],
        **attempt_fields(attempt_id=parent_id),
    )


@pytest.mark.parametrize("field", ["usage_source", "cost_source"])
@pytest.mark.parametrize("source", ["", 0, 1, False, True, [], {}])
def test_aggregate_validator_rejects_mirrored_invalid_partial_source(field, source):
    aggregate = partial_aggregate()
    aggregate[field] = source
    aggregate["reconciliation"][field] = source

    with pytest.raises(ValueError, match=rf"{field} must be a non-empty string"):
        receipts.validate_attempt(aggregate)


@pytest.mark.parametrize("field", ["usage_source", "cost_source"])
@pytest.mark.parametrize("source", ["", 0, 1, False, True, [], {}])
def test_reconciliation_validator_rejects_invalid_partial_source(field, source):
    aggregate = partial_aggregate()
    aggregate["reconciliation"][field] = source

    with pytest.raises(ValueError, match=rf"{field} must be a non-empty string"):
        receipts.validate_attempt(aggregate)


@pytest.mark.parametrize("field", ["usage_source", "cost_source"])
def test_partial_aggregate_source_may_be_null_per_schema(field):
    aggregate = partial_aggregate()
    aggregate[field] = None
    aggregate["reconciliation"][field] = None

    receipts.validate_attempt(aggregate)


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
