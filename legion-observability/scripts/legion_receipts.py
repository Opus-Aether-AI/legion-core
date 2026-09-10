#!/usr/bin/env python3
"""Construct and reconcile typed executor failure/attempt receipts."""

from __future__ import annotations

import math
from datetime import datetime, timezone
from decimal import Decimal
import uuid


FAILURE_CLASSES = frozenset(
    {"auth", "quota", "capacity", "transport", "malformed_event", "cancelled",
     "timed_out", "incompatible", "unavailable", "policy_refused", "provider",
     "internal", "unknown"}
)
TERMINAL_STATUSES = frozenset({"succeeded", "failed", "cancelled", "timed_out", "refused"})
PROVENANCE_STATUSES = frozenset({"known", "partial", "unknown", "not_applicable"})


def _now():
    return datetime.now(timezone.utc).isoformat().replace("+00:00", "Z")


def _identifier(prefix):
    return f"{prefix}-{uuid.uuid4().hex}"


def _require_string(name, value, nullable=False):
    if value is None and nullable:
        return
    if not isinstance(value, str) or not value:
        raise ValueError(f"{name} must be a non-empty string")


def _validate_usage(value):
    if not isinstance(value, dict):
        raise ValueError("usage must be an object when known")
    for name, count in value.items():
        _require_string("usage key", name)
        if isinstance(count, bool) or not isinstance(count, int) or count < 0:
            raise ValueError(f"usage.{name} must be a non-negative integer")


def _validate_provenance(kind, value, status, source, *, aggregate=False):
    allowed = PROVENANCE_STATUSES if aggregate else PROVENANCE_STATUSES - {"partial"}
    if status not in allowed:
        raise ValueError(f"{kind}_status must be one of {sorted(allowed)}")
    if status == "known":
        if value is None:
            raise ValueError(f"known {kind} requires a value")
        _require_string(f"{kind}_source", source)
    elif value is not None:
        raise ValueError(f"{kind} must be null when {kind}_status is {status}")
    elif status in {"unknown", "not_applicable"} and source is not None:
        raise ValueError(f"{kind}_source must be null when {kind}_status is {status}")
    if kind == "usage" and value is not None:
        _validate_usage(value)
    if kind == "cost":
        if value is not None and (isinstance(value, bool) or not isinstance(value, (int, float))
                                  or not math.isfinite(value) or value < 0):
            raise ValueError("cost_usd must be a finite non-negative number")


def _validate_reconciliation(value):
    expected = {"usage", "usage_status", "usage_source", "known_usage",
                "known_usage_attempts", "cost_usd", "cost_status", "cost_source",
                "known_cost_usd", "known_cost_attempts", "attempt_count"}
    if not isinstance(value, dict) or set(value) != expected:
        raise ValueError("aggregate reconciliation has missing or unknown fields")
    total = value["attempt_count"]
    if isinstance(total, bool) or not isinstance(total, int) or total < 1:
        raise ValueError("aggregate attempt_count must be positive")
    for kind in ("usage", "cost"):
        count = value[f"known_{kind}_attempts"]
        if isinstance(count, bool) or not isinstance(count, int) or not 0 <= count <= total:
            raise ValueError(f"aggregate known_{kind}_attempts is invalid")
        expected_status = "known" if count == total else ("partial" if count else "unknown")
        if value[f"{kind}_status"] != expected_status:
            raise ValueError(f"aggregate {kind}_status does not match its known count")
    known_usage = value["known_usage"]
    if value["known_usage_attempts"]:
        _validate_usage(known_usage)
    elif known_usage is not None:
        raise ValueError("aggregate known_usage must be null when no usage is known")
    known_cost = value["known_cost_usd"]
    if value["known_cost_attempts"]:
        _validate_provenance("cost", known_cost, "known", value["cost_source"] or "mixed")
    elif known_cost is not None:
        raise ValueError("aggregate known_cost_usd must be null when no cost is known")
    _validate_provenance("usage", value["usage"], value["usage_status"], value["usage_source"], aggregate=True)
    _validate_provenance("cost", value["cost_usd"], value["cost_status"], value["cost_source"], aggregate=True)


def _validate_cache_lineage(value):
    if value is None:
        return
    if not isinstance(value, dict) or set(value) != {"preflight_cache_key", "previous_attempt_id"}:
        raise ValueError("cache_lineage must contain preflight_cache_key and previous_attempt_id")
    for name, item in value.items():
        if item is not None:
            _require_string(f"cache_lineage.{name}", item)


def _validate_terminal_failure(terminal_status, failure):
    if terminal_status == "succeeded":
        if failure is not None:
            raise ValueError("successful attempts cannot contain a typed failure")
    elif failure is None:
        raise ValueError("non-successful attempts require a typed failure")


def failure_receipt(*, run_id, attempt_id, failure_class, retryable, output_started,
                    provider_code=None, message=None, failure_id=None, ts=None):
    _require_string("run_id", run_id)
    _require_string("attempt_id", attempt_id)
    if failure_class not in FAILURE_CLASSES:
        raise ValueError(f"failure_class must be one of {sorted(FAILURE_CLASSES)}")
    if not isinstance(retryable, bool) or not isinstance(output_started, bool):
        raise ValueError("retryable and output_started must be booleans")
    if provider_code is not None:
        _require_string("provider_code", provider_code)
    if message is not None:
        _require_string("message", message)
    return {
        "schema": "legion.failure.v1", "failure_id": failure_id or _identifier("failure"),
        "run_id": run_id, "attempt_id": attempt_id, "ts": ts or _now(),
        "class": failure_class, "provider_code": provider_code, "retryable": retryable,
        "output_started": output_started, "message": message,
    }


def validate_failure(receipt):
    if not isinstance(receipt, dict) or receipt.get("schema") != "legion.failure.v1":
        raise ValueError("failure receipt must use legion.failure.v1")
    expected = {"schema", "failure_id", "run_id", "attempt_id", "ts", "class",
                "provider_code", "retryable", "output_started", "message"}
    if set(receipt) != expected:
        raise ValueError("failure receipt has missing or unknown fields")
    rebuilt = failure_receipt(
        run_id=receipt["run_id"], attempt_id=receipt["attempt_id"],
        failure_class=receipt["class"], retryable=receipt["retryable"],
        output_started=receipt["output_started"], provider_code=receipt["provider_code"],
        message=receipt["message"], failure_id=receipt["failure_id"], ts=receipt["ts"],
    )
    return rebuilt


def attempt_receipt(*, run_id, ordinal, executor, provider, config_identity,
                    requested_model, effective_model, requested_effort, effective_effort,
                    sandbox, terminal_status, started_at, ended_at, duration_ms,
                    usage=None, usage_status="unknown", usage_source=None,
                    cost_usd=None, cost_status="unknown", cost_source=None,
                    failure=None, output_started=False, parent_attempt_id=None,
                    cache_lineage=None, attempt_id=None, child_attempts=None):
    for name, value in (("run_id", run_id), ("executor", executor), ("provider", provider),
                        ("config_identity", config_identity), ("sandbox", sandbox),
                        ("started_at", started_at), ("ended_at", ended_at)):
        _require_string(name, value)
    for name, value in (("requested_model", requested_model), ("effective_model", effective_model),
                        ("requested_effort", requested_effort), ("effective_effort", effective_effort),
                        ("parent_attempt_id", parent_attempt_id)):
        if value is not None:
            _require_string(name, value)
    if isinstance(ordinal, bool) or not isinstance(ordinal, int) or ordinal < 1:
        raise ValueError("ordinal must be a positive integer")
    if terminal_status not in TERMINAL_STATUSES:
        raise ValueError(f"terminal_status must be one of {sorted(TERMINAL_STATUSES)}")
    if isinstance(duration_ms, bool) or not isinstance(duration_ms, (int, float)) or duration_ms < 0:
        raise ValueError("duration_ms must be non-negative")
    if not isinstance(output_started, bool):
        raise ValueError("output_started must be a boolean")
    reconciliation = None
    children = []
    if child_attempts is not None:
        child_attempts = list(child_attempts)
        reconciliation = reconcile_attempts(child_attempts)
        children = [child["attempt_id"] for child in child_attempts]
        output_started = any(child["output_started"] for child in child_attempts)
        usage = reconciliation["usage"]
        usage_status = reconciliation["usage_status"]
        usage_source = reconciliation["usage_source"]
        cost_usd = reconciliation["cost_usd"]
        cost_status = reconciliation["cost_status"]
        cost_source = reconciliation["cost_source"]
    _validate_provenance("usage", usage, usage_status, usage_source, aggregate=child_attempts is not None)
    _validate_provenance("cost", cost_usd, cost_status, cost_source, aggregate=child_attempts is not None)
    _validate_cache_lineage(cache_lineage)
    _validate_terminal_failure(terminal_status, failure)
    if failure is not None:
        validate_failure(failure)
        if failure["run_id"] != run_id:
            raise ValueError("failure run_id does not match attempt")
        if failure["attempt_id"] != (attempt_id or failure["attempt_id"]):
            raise ValueError("failure attempt_id does not match attempt")
        if failure["output_started"] != output_started:
            raise ValueError("failure output_started does not match attempt")
    actual_attempt_id = attempt_id or (failure["attempt_id"] if failure is not None else _identifier("attempt"))
    if child_attempts is not None:
        if any(child["run_id"] != run_id for child in child_attempts):
            raise ValueError("aggregate children must share the parent run_id")
        if any(child["parent_attempt_id"] != actual_attempt_id for child in child_attempts):
            raise ValueError("aggregate child parent_attempt_id does not match parent")
    return {
        "schema": "legion.attempt.v1", "attempt_id": actual_attempt_id,
        "attempt_kind": "aggregate" if child_attempts is not None else "provider",
        "run_id": run_id, "parent_attempt_id": parent_attempt_id, "ordinal": ordinal,
        "executor": executor, "provider": provider, "config_identity": config_identity,
        "requested_model": requested_model, "effective_model": effective_model,
        "requested_effort": requested_effort, "effective_effort": effective_effort,
        "cache_lineage": cache_lineage, "usage": usage, "usage_status": usage_status,
        "usage_source": usage_source, "cost_usd": cost_usd, "cost_status": cost_status,
        "cost_source": cost_source, "failure": failure, "output_started": output_started,
        "started_at": started_at, "ended_at": ended_at, "duration_ms": duration_ms,
        "sandbox": sandbox, "terminal_status": terminal_status,
        "child_attempt_ids": children, "reconciliation": reconciliation,
    }


def reconcile_attempts(attempts):
    """Return exact known sums while preserving any unknown child as nullable."""
    attempts = list(attempts)
    if not attempts:
        raise ValueError("at least one child attempt is required")
    for attempt in attempts:
        validate_attempt(attempt)
    attempt_ids = [attempt.get("attempt_id") for attempt in attempts]
    if len(set(attempt_ids)) != len(attempt_ids):
        raise ValueError("child attempt ids must be unique")
    ordinals = [attempt.get("ordinal") for attempt in attempts]
    if ordinals != list(range(1, len(attempts) + 1)):
        raise ValueError("child attempt ordinals must be contiguous and ordered from one")
    known_usage = {}
    usage_known = 0
    known_cost_values = []
    cost_known = 0
    attempt_count = 0
    usage_sources = set()
    cost_sources = set()
    for attempt in attempts:
        aggregate = attempt["reconciliation"] if attempt["attempt_kind"] == "aggregate" else None
        leaf_count = aggregate["attempt_count"] if aggregate is not None else 1
        attempt_count += leaf_count
        usage_value = aggregate["known_usage"] if aggregate is not None else attempt["usage"]
        usage_value_count = aggregate["known_usage_attempts"] if aggregate is not None else (
            1 if attempt["usage_status"] == "known" else 0
        )
        if usage_value_count:
            usage_known += usage_value_count
            usage_sources.add(attempt["usage_source"])
            for key, value in usage_value.items():
                known_usage[key] = known_usage.get(key, 0) + value
        cost_value = aggregate["known_cost_usd"] if aggregate is not None else attempt["cost_usd"]
        cost_value_count = aggregate["known_cost_attempts"] if aggregate is not None else (
            1 if attempt["cost_status"] == "known" else 0
        )
        if cost_value_count:
            cost_known += cost_value_count
            cost_sources.add(attempt["cost_source"])
            known_cost_values.append(Decimal(str(cost_value)))
    known_cost = float(sum(known_cost_values, Decimal("0")))
    usage_status = "known" if usage_known == attempt_count else ("partial" if usage_known else "unknown")
    cost_status = "known" if cost_known == attempt_count else ("partial" if cost_known else "unknown")
    return {
        "usage": known_usage if usage_status == "known" else None,
        "usage_status": usage_status,
        "usage_source": (next(iter(usage_sources)) if len(usage_sources) == 1 else "mixed") if usage_known else None,
        "known_usage": known_usage if usage_known else None,
        "known_usage_attempts": usage_known,
        "cost_usd": known_cost if cost_status == "known" else None,
        "cost_status": cost_status,
        "cost_source": (next(iter(cost_sources)) if len(cost_sources) == 1 else "mixed") if cost_known else None,
        "known_cost_usd": known_cost if cost_known else None,
        "known_cost_attempts": cost_known,
        "attempt_count": attempt_count,
    }


def validate_attempt(receipt):
    if not isinstance(receipt, dict) or receipt.get("schema") != "legion.attempt.v1":
        raise ValueError("attempt receipt must use legion.attempt.v1")
    expected = {"schema", "attempt_id", "attempt_kind", "run_id", "parent_attempt_id", "ordinal", "executor",
                "provider", "config_identity", "requested_model", "effective_model",
                "requested_effort", "effective_effort", "cache_lineage", "usage",
                "usage_status", "usage_source", "cost_usd", "cost_status", "cost_source",
                "failure", "output_started", "started_at", "ended_at", "duration_ms",
                "sandbox", "terminal_status", "child_attempt_ids", "reconciliation"}
    if set(receipt) != expected:
        raise ValueError("attempt receipt has missing or unknown fields")
    for name in ("attempt_id", "run_id", "executor", "provider", "config_identity",
                 "sandbox", "started_at", "ended_at"):
        _require_string(name, receipt[name])
    for name in ("requested_model", "effective_model", "requested_effort", "effective_effort",
                 "parent_attempt_id"):
        if receipt[name] is not None:
            _require_string(name, receipt[name])
    _validate_cache_lineage(receipt["cache_lineage"])
    if isinstance(receipt["ordinal"], bool) or not isinstance(receipt["ordinal"], int) \
            or receipt["ordinal"] < 1:
        raise ValueError("ordinal must be a positive integer")
    if receipt["terminal_status"] not in TERMINAL_STATUSES:
        raise ValueError("invalid terminal_status")
    if not isinstance(receipt["output_started"], bool):
        raise ValueError("output_started must be a boolean")
    if isinstance(receipt["duration_ms"], bool) or not isinstance(receipt["duration_ms"], (int, float)) \
            or receipt["duration_ms"] < 0:
        raise ValueError("duration_ms must be non-negative")
    _validate_terminal_failure(receipt["terminal_status"], receipt["failure"])
    if receipt["failure"] is not None:
        validate_failure(receipt["failure"])
        if receipt["failure"]["run_id"] != receipt["run_id"] \
                or receipt["failure"]["attempt_id"] != receipt["attempt_id"] \
                or receipt["failure"]["output_started"] != receipt["output_started"]:
            raise ValueError("failure lineage does not match attempt")
    if receipt["attempt_kind"] not in {"provider", "aggregate"}:
        raise ValueError("attempt_kind must be provider or aggregate")
    if receipt["attempt_kind"] == "provider":
        if receipt["child_attempt_ids"] or receipt["reconciliation"] is not None:
            raise ValueError("provider attempts cannot contain child reconciliation")
    else:
        reconciliation = receipt["reconciliation"]
        child_ids = receipt["child_attempt_ids"]
        if not isinstance(child_ids, list) or not child_ids \
                or not all(isinstance(value, str) and value for value in child_ids) \
                or len(set(child_ids)) != len(child_ids) or not isinstance(reconciliation, dict):
            raise ValueError("aggregate attempts require child reconciliation")
        _validate_reconciliation(reconciliation)
        _validate_provenance("usage", receipt["usage"], receipt["usage_status"], receipt["usage_source"], aggregate=True)
        _validate_provenance("cost", receipt["cost_usd"], receipt["cost_status"], receipt["cost_source"], aggregate=True)
        for field in ("usage", "usage_status", "usage_source", "cost_usd", "cost_status", "cost_source"):
            if receipt[field] != reconciliation[field]:
                raise ValueError(f"aggregate {field} does not match reconciliation")
        return receipt
    rebuilt = attempt_receipt(**{
        "run_id": receipt["run_id"], "ordinal": receipt["ordinal"],
        "executor": receipt["executor"], "provider": receipt["provider"],
        "config_identity": receipt["config_identity"], "requested_model": receipt["requested_model"],
        "effective_model": receipt["effective_model"], "requested_effort": receipt["requested_effort"],
        "effective_effort": receipt["effective_effort"], "sandbox": receipt["sandbox"],
        "terminal_status": receipt["terminal_status"], "started_at": receipt["started_at"],
        "ended_at": receipt["ended_at"], "duration_ms": receipt["duration_ms"],
        "usage": receipt["usage"], "usage_status": receipt["usage_status"],
        "usage_source": receipt["usage_source"], "cost_usd": receipt["cost_usd"],
        "cost_status": receipt["cost_status"], "cost_source": receipt["cost_source"],
        "failure": receipt["failure"], "output_started": receipt["output_started"],
        "parent_attempt_id": receipt["parent_attempt_id"], "cache_lineage": receipt["cache_lineage"],
        "attempt_id": receipt["attempt_id"],
    })
    if rebuilt != receipt:
        raise ValueError("provider attempt fields do not match the contract")
    return rebuilt


def aggregate_attempt_receipt(*, child_attempts, **parent):
    """Build a parent ``legion.attempt.v1`` with mechanically derived totals."""
    return attempt_receipt(child_attempts=child_attempts, **parent)


def validate_aggregate_reconciliation(parent, child_attempts):
    """Reject a parent whose lineage or known subtotal differs from its children."""
    validate_attempt(parent)
    if parent["attempt_kind"] != "aggregate":
        raise ValueError("parent must be an aggregate attempt")
    children = list(child_attempts)
    expected = reconcile_attempts(children)
    if parent["child_attempt_ids"] != [child["attempt_id"] for child in children]:
        raise ValueError("aggregate child attempt lineage does not reconcile")
    if any(child["run_id"] != parent["run_id"] or child["parent_attempt_id"] != parent["attempt_id"]
           for child in children):
        raise ValueError("aggregate child parent/run lineage does not reconcile")
    if parent["reconciliation"] != expected:
        raise ValueError("aggregate known usage/cost does not reconcile")
    for field in ("usage", "usage_status", "usage_source", "cost_usd", "cost_status", "cost_source"):
        if parent[field] != expected[field]:
            raise ValueError(f"aggregate {field} does not reconcile")
    return parent
