#!/usr/bin/env python3
"""Classify a primary harness checkpoint by semantic progress, not wall time."""

from __future__ import annotations

import argparse
from datetime import datetime, timezone
import fcntl
import hashlib
import json
import os
from pathlib import Path
import re
import stat
import sys
from typing import Any

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import legion_state  # noqa: E402


CHECKPOINT_SCHEMA = "legion.convergence-checkpoint.v1"
DECISION_SCHEMA = "legion.convergence-decision.v1"
VALID_SCOPES = {"external", "local"}
VALID_STATUSES = {"failed", "passed", "pending"}


class ConvergenceError(ValueError):
    """Raised when a checkpoint cannot prove a safe convergence decision."""


def _digest(value: Any) -> str:
    encoded = json.dumps(
        value,
        ensure_ascii=True,
        separators=(",", ":"),
        sort_keys=True,
    ).encode("utf-8")
    return hashlib.sha256(encoded).hexdigest()


def _required_string(container: dict[str, Any], key: str, context: str) -> str:
    value = container.get(key)
    if not isinstance(value, str) or not value.strip():
        raise ConvergenceError(f"{context}.{key} must be a non-empty string")
    return value.strip()


def _finding_fingerprints(review: dict[str, Any], key: str) -> list[str]:
    if key not in review:
        raise ConvergenceError(f"review.{key} is required")
    findings = review[key]
    if not isinstance(findings, list):
        raise ConvergenceError(f"review.{key} must be a list")
    fingerprints: list[str] = []
    for index, finding in enumerate(findings):
        if not isinstance(finding, dict):
            raise ConvergenceError(f"review.{key}[{index}] must be an object")
        fingerprints.append(
            _required_string(finding, "fingerprint", f"review.{key}[{index}]")
        )
    return sorted(fingerprints)


def _normalize_checkpoint(payload: dict[str, Any]) -> dict[str, Any]:
    if not isinstance(payload, dict):
        raise ConvergenceError("checkpoint must be a JSON object")
    if payload.get("schema") != CHECKPOINT_SCHEMA:
        raise ConvergenceError(f"schema must be {CHECKPOINT_SCHEMA}")

    task_id = _required_string(payload, "task_id", "checkpoint")
    source = _required_string(payload, "source_fingerprint", "checkpoint")
    checks = payload.get("checks")
    if not isinstance(checks, list) or not checks:
        raise ConvergenceError("checkpoint.checks must be a non-empty list")

    normalized_checks: list[dict[str, str]] = []
    check_ids: set[str] = set()
    for index, check in enumerate(checks):
        context = f"checkpoint.checks[{index}]"
        if not isinstance(check, dict):
            raise ConvergenceError(f"{context} must be an object")
        check_id = _required_string(check, "id", context)
        if check_id in check_ids:
            raise ConvergenceError(f"duplicate check id: {check_id}")
        check_ids.add(check_id)
        scope = _required_string(check, "scope", context)
        status = _required_string(check, "status", context)
        evidence = _required_string(check, "evidence_fingerprint", context)
        if scope not in VALID_SCOPES:
            raise ConvergenceError(f"{context}.scope must be local or external")
        if status not in VALID_STATUSES:
            raise ConvergenceError(
                f"{context}.status must be failed, passed, or pending"
            )
        normalized_checks.append(
            {
                "id": check_id,
                "scope": scope,
                "status": status,
                "evidence_fingerprint": evidence,
            }
        )

    if "review" not in payload:
        raise ConvergenceError("checkpoint.review is required")
    review = payload["review"]
    if not isinstance(review, dict):
        raise ConvergenceError("checkpoint.review must be an object")
    blocking = _finding_fingerprints(review, "blocking_findings")
    suggestions = _finding_fingerprints(review, "suggestions")
    if "head_sha" not in review or not isinstance(review["head_sha"], str):
        raise ConvergenceError("review.head_sha must be a string")
    head_sha = review["head_sha"].strip()
    if blocking and not re.fullmatch(r"[0-9a-fA-F]{7,64}", head_sha):
        raise ConvergenceError(
            "review.head_sha must be an immutable commit SHA when blocking findings are present"
        )

    return {
        "task_id": task_id,
        "source_fingerprint": source,
        "checks": sorted(normalized_checks, key=lambda item: item["id"]),
        "review": {
            "head_sha": head_sha,
            "blocking_findings": blocking,
            "suggestions": suggestions,
        },
    }


def evaluate_checkpoint(
    payload: dict[str, Any], previous: dict[str, Any] | None = None
) -> dict[str, Any]:
    """Return the next semantic state for a validated checkpoint."""

    checkpoint = _normalize_checkpoint(payload)
    checks = checkpoint["checks"]
    failed = [item["id"] for item in checks if item["status"] == "failed"]
    pending_local = [
        item["id"]
        for item in checks
        if item["status"] == "pending" and item["scope"] == "local"
    ]
    pending_external = [
        item["id"]
        for item in checks
        if item["status"] == "pending" and item["scope"] == "external"
    ]
    blocking = checkpoint["review"]["blocking_findings"]
    suggestions = checkpoint["review"]["suggestions"]

    source_hash = _digest(checkpoint["source_fingerprint"])
    actionable_evidence = {
        "blocking_review": [
            {
                "fingerprint": fingerprint,
                "head_sha": checkpoint["review"]["head_sha"],
            }
            for fingerprint in blocking
        ],
        "checks": [
            item
            for item in checks
            if item["status"] == "failed"
            or (item["status"] == "pending" and item["scope"] == "local")
        ],
    }
    evidence_hash = _digest(actionable_evidence)

    common: dict[str, Any] = {
        "source_fingerprint_hash": source_hash,
        "failure_evidence_fingerprint": evidence_hash,
        "failed_checks": failed,
        "pending_local": pending_local,
        "pending_external": pending_external,
        "blocking_finding_count": len(blocking),
        "suggestion_count": len(suggestions),
    }
    if failed or pending_local or blocking:
        reason = (
            "blocking_review_finding"
            if blocking
            else "required_check_failed"
            if failed
            else "local_check_pending"
        )
        if previous:
            same_source = previous.get("source_fingerprint_hash") == source_hash
            same_evidence = (
                previous.get("failure_evidence_fingerprint") == evidence_hash
            )
            if same_source and same_evidence:
                return {
                    **common,
                    "state": "blocked",
                    "action": "yield",
                    "reason": "no_progress",
                }
            if same_source and not same_evidence:
                reason = "new_failure_evidence"
        return {
            **common,
            "state": "actionable",
            "action": "continue",
            "reason": reason,
        }

    if pending_external:
        return {
            **common,
            "state": "waiting_external",
            "action": "yield",
            "reason": "external_checks_pending",
        }

    return {
        **common,
        "state": "complete",
        "action": "yield",
        "reason": "all_required_evidence_passed",
    }


def _latest_record(descriptor: int) -> dict[str, Any] | None:
    end = os.lseek(descriptor, 0, os.SEEK_END)
    start = max(0, end - 1024 * 1024)
    os.lseek(descriptor, start, os.SEEK_SET)
    raw = bytearray()
    while len(raw) < end - start:
        chunk = os.read(descriptor, min(65536, end - start - len(raw)))
        if not chunk:
            break
        raw.extend(chunk)
    lines = raw.decode("utf-8", errors="ignore").splitlines()
    if start and lines:
        lines = lines[1:]
    for line in reversed(lines):
        try:
            record = json.loads(line)
        except ValueError:
            continue
        if isinstance(record, dict) and record.get("schema") == DECISION_SCHEMA:
            return record
    return None


def _record_decision(
    descriptor: int, task_id: str, decision: dict[str, Any]
) -> dict[str, Any]:
    record = {
        "schema": DECISION_SCHEMA,
        "recorded_at": datetime.now(timezone.utc).isoformat().replace("+00:00", "Z"),
        "task_id_hash": _digest(task_id),
        **decision,
    }
    encoded = (json.dumps(record, ensure_ascii=True, sort_keys=True) + "\n").encode(
        "utf-8"
    )
    remaining = memoryview(encoded)
    while remaining:
        written = os.write(descriptor, remaining)
        if written <= 0:
            raise OSError("could not append convergence decision")
        remaining = remaining[written:]
    return record


def _open_history(state_root: Path, task_id: str) -> int:
    nofollow = getattr(os, "O_NOFOLLOW", 0)
    directory = getattr(os, "O_DIRECTORY", 0)
    if not nofollow or not directory:
        raise ConvergenceError("secure convergence journals require O_NOFOLLOW")

    state_root.mkdir(parents=True, exist_ok=True)
    state_descriptor = os.open(state_root, os.O_RDONLY | directory)
    convergence_descriptor = -1
    try:
        try:
            os.mkdir("convergence", mode=0o700, dir_fd=state_descriptor)
        except FileExistsError:
            pass
        try:
            convergence_descriptor = os.open(
                "convergence",
                os.O_RDONLY | directory | nofollow,
                dir_fd=state_descriptor,
            )
        except OSError as error:
            raise ConvergenceError(
                "convergence journal directory must be a real directory"
            ) from error
    finally:
        os.close(state_descriptor)

    try:
        os.fchmod(convergence_descriptor, 0o700)
        journal_name = f"{_digest(task_id)}.jsonl"
        try:
            descriptor = os.open(
                journal_name,
                os.O_RDWR | os.O_APPEND | os.O_CREAT | nofollow,
                0o600,
                dir_fd=convergence_descriptor,
            )
        except OSError as error:
            raise ConvergenceError(
                "convergence journal must be a non-symlink regular file"
            ) from error
    finally:
        os.close(convergence_descriptor)

    if not stat.S_ISREG(os.fstat(descriptor).st_mode):
        os.close(descriptor)
        raise ConvergenceError("convergence journal must be a regular file")
    os.fchmod(descriptor, 0o600)
    return descriptor


def checkpoint(payload: dict[str, Any], *, state_root: Path) -> dict[str, Any]:
    normalized = _normalize_checkpoint(payload)
    lock_descriptor = _open_history(
        Path(state_root).expanduser(), normalized["task_id"]
    )
    locked = False
    try:
        fcntl.flock(lock_descriptor, fcntl.LOCK_EX)
        locked = True
        previous = _latest_record(lock_descriptor)
        decision = evaluate_checkpoint(payload, previous=previous)
        _record_decision(lock_descriptor, normalized["task_id"], decision)
    finally:
        if locked:
            fcntl.flock(lock_descriptor, fcntl.LOCK_UN)
        os.close(lock_descriptor)
    return decision


def _read_payload(path: str) -> dict[str, Any]:
    if path == "-":
        raw = sys.stdin.read()
    else:
        raw = Path(path).read_text(encoding="utf-8")
    try:
        payload = json.loads(raw)
    except ValueError as error:
        raise ConvergenceError(f"invalid checkpoint JSON: {error}") from error
    if not isinstance(payload, dict):
        raise ConvergenceError("checkpoint must be a JSON object")
    return payload


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(
        prog="legion-converge",
        description="Classify primary-harness progress without an arbitrary deadline.",
    )
    parser.add_argument(
        "--checkpoint",
        required=True,
        help="checkpoint JSON file, or - for stdin",
    )
    parser.add_argument("--repo", default=".", help="repository used to resolve state")
    parser.add_argument("--state-root", help="override the resolved Legion state root")
    parser.add_argument(
        "--no-record",
        action="store_true",
        help="evaluate without comparing or recording task history",
    )
    parser.add_argument("--json", action="store_true", help="emit the full decision")
    args = parser.parse_args(argv)

    try:
        payload = _read_payload(args.checkpoint)
        if args.no_record:
            decision = evaluate_checkpoint(payload)
        else:
            state_root = (
                Path(args.state_root).expanduser()
                if args.state_root
                else Path(legion_state.resolve_state(args.repo)["state_root"])
            )
            decision = checkpoint(payload, state_root=state_root)
    except (ConvergenceError, OSError) as error:
        print(f"legion-converge: {error}", file=sys.stderr)
        return 2

    if args.json:
        print(json.dumps(decision, ensure_ascii=True, sort_keys=True))
    else:
        print(
            f"legion-converge: {decision['state']} -> {decision['action']} "
            f"({decision['reason']})"
        )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
