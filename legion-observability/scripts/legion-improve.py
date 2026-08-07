#!/usr/bin/env python3
"""Crash-safe, review-only conversion of typed learning into draft PRs.

The engine intentionally supports one small mutation vocabulary. Proposals may
describe a Markdown guardrail, but they cannot supply a shell command. Every
candidate is built from an exact remote tip in an isolated Git worktree, tested
repeatedly, reviewed through ``legion-delegate review``, and published only as
an idempotent draft PR.
"""
from __future__ import annotations

import argparse
import fcntl
import hashlib
import json
import math
import os
import re
import selectors
import shutil
import signal
import subprocess
import sys
import tempfile
import time
from pathlib import Path
from typing import Any

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import legion_state  # noqa: E402


PROPOSAL_SCHEMA = "legion.improvement-proposal.v1"
RUN_SCHEMA = "legion.improvement-run.v1"
ERROR_SCHEMA = "legion.improvement-error.v1"
REVIEW_SCHEMA = "legion.improvement-review-receipt.v1"
QUEUE_SCHEMA = "legion.improvement-queue-run.v1"
IMPROVEMENT_PR_BODY = (
    "Review-only Legion improvement. The exact remote base and candidate "
    "passed repeated paired gates plus an independent immutable review. "
    "Human review is required; this automation cannot merge or deploy."
)
STEPS = (
    "eligible",
    "leased",
    "prepared",
    "candidate_ready",
    "evaluated",
    "reviewed",
    "draft_created",
)
TERMINAL = {"rejected", "stale", "failed", "draft_created"}
MAX_PROCESS_OUTPUT = 65_536
MAX_GIT_OUTPUT = 2_097_152
MAX_SOURCE_BYTES = 1_048_576
MAX_PROPOSAL_BYTES = 65_536
# Consecutive empty pull-request listings tolerated against a recorded
# publish intent before concluding nothing was ever published.
RECONCILE_ATTEMPTS = 3
# Exit codes _bounded_process synthesizes after killing a child locally.
# The child never reported them, so a request it already sent may still
# have succeeded remotely: treat these as ambiguous, never as failure.
_AMBIGUOUS_PROCESS_CODES = frozenset({124, 125})
EMPTY_DIFF = hashlib.sha256(b"").hexdigest()
REVIEW_RETRYABLE = {"independent_review_unavailable", "independent_review_failed"}
DRAFT_RETRYABLE = {
    "branch_push_failed",
    "gh_unavailable",
    "draft_pr_list_failed",
    "draft_pr_create_failed",
    "draft_pr_response_invalid",
    "draft_pr_verify_failed",
    "draft_base_changed",
    "draft_pr_rollback_failed",
    "draft_pr_rolled_back",
    "draft_pr_reconcile_pending",
}
TERMINAL_RETRYABLE_WITHOUT_INPUT_CHANGE = {
    "repository_unavailable",
    "remote_not_configured",
    "remote_tip_unavailable",
    "remote_base_fetch_failed",
    "base_not_remote_tip",
    "operator_checkout_dirty",
    "state_corrupt",
    "internal_operation_failed",
    "worktree_prepare_failed",
    "candidate_reset_failed",
    "changed_paths_unavailable",
    "candidate_target_unavailable",
    "candidate_target_invalid_utf8",
    "baseline_failed",
    "baseline_variance",
    "candidate_variance",
    "baseline_mutated",
    "candidate_mutated",
    "regression",
    "review_snapshot_failed",
    "review_snapshot_mismatch",
    "independent_review_invalid",
}


class ImproveError(Exception):
    def __init__(self, state: str, reason: str):
        self.state = state
        self.reason = reason
        super().__init__(reason)


ROOT = Path(__file__).resolve().parents[2]
# The daily refresh runs from cron, whose PATH is a bare /usr/bin:/bin, and
# refresh.sh deliberately invokes every sibling Legion binary by absolute path
# for exactly that reason. Legion binaries ship in this repository so they can
# be resolved directly; `gh` cannot, and is handled by the PATH extension in
# scripts/refresh.sh instead.
COMMAND_FALLBACKS = {
    "legion-delegate": ROOT / "legion-router" / "bin" / "legion-delegate",
}


def _resolve_command(configured: str) -> str:
    """Resolve an external command, falling back to the in-repo copy."""
    if os.path.isabs(configured):
        return configured
    found = shutil.which(configured)
    if found:
        return found
    fallback = COMMAND_FALLBACKS.get(configured)
    if fallback and os.access(fallback, os.X_OK):
        return str(fallback)
    return ""


def canonical(value: Any) -> bytes:
    return json.dumps(
        value, sort_keys=True, separators=(",", ":"), ensure_ascii=True
    ).encode("utf-8")


def digest(value: Any) -> str:
    payload = value if isinstance(value, bytes) else canonical(value)
    return hashlib.sha256(payload).hexdigest()


def proposal_fingerprint(proposal: dict[str, Any]) -> str:
    """Identify the proposed change, excluding evidence that may keep growing."""
    return digest(
        {
            "schema": proposal["schema"],
            "id": proposal["id"],
            "kind": proposal["kind"],
            "target": proposal["target"],
            "candidate": proposal["candidate"],
            "validation": proposal["validation"],
            "limits": proposal.get("limits") or {},
        }
    )


def _bounded_process(
    argv: list[str],
    *,
    cwd: str | Path | None = None,
    env: dict[str, str] | None = None,
    timeout: int = 120,
    output_limit: int = MAX_PROCESS_OUTPUT,
) -> subprocess.CompletedProcess[str]:
    """Run without a shell and enforce time and output bounds while streaming."""
    try:
        process = subprocess.Popen(
            argv,
            cwd=str(cwd) if cwd is not None else None,
            env=env,
            stdin=subprocess.DEVNULL,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            start_new_session=True,
        )
    except OSError as exc:
        return subprocess.CompletedProcess(argv, 127, "", str(exc)[:output_limit])
    streams = {process.stdout: bytearray(), process.stderr: bytearray()}
    selector = selectors.DefaultSelector()
    for stream in streams:
        assert stream is not None
        os.set_blocking(stream.fileno(), False)
        selector.register(stream, selectors.EVENT_READ)
    deadline = time.monotonic() + timeout
    exceeded = False
    timed_out = False
    try:
        while selector.get_map():
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                timed_out = True
                break
            for key, _ in selector.select(min(remaining, 0.25)):
                stream = key.fileobj
                try:
                    chunk = os.read(stream.fileno(), 65_536)
                except BlockingIOError:
                    continue
                if not chunk:
                    selector.unregister(stream)
                    continue
                streams[stream].extend(chunk)
                if sum(len(value) for value in streams.values()) > output_limit:
                    exceeded = True
                    break
            if exceeded:
                break
    finally:
        selector.close()
    if timed_out or exceeded:
        try:
            os.killpg(process.pid, signal.SIGTERM)
        except ProcessLookupError:
            pass
        try:
            process.wait(timeout=2)
        except subprocess.TimeoutExpired:
            try:
                os.killpg(process.pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
            process.wait()
        for stream in streams:
            assert stream is not None
            stream.close()
        if timed_out:
            return subprocess.CompletedProcess(argv, 124, "", "process timed out")
        return subprocess.CompletedProcess(argv, 125, "", "process output exceeded limit")
    try:
        process.wait(timeout=max(0.0, deadline - time.monotonic()))
    except subprocess.TimeoutExpired:
        timed_out = True
    if timed_out:
        try:
            os.killpg(process.pid, signal.SIGTERM)
        except ProcessLookupError:
            pass
        try:
            process.wait(timeout=2)
        except subprocess.TimeoutExpired:
            try:
                os.killpg(process.pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
            process.wait()
        for stream in streams:
            assert stream is not None
            stream.close()
        return subprocess.CompletedProcess(argv, 124, "", "process timed out")
    stdout = bytes(streams[process.stdout])
    stderr = bytes(streams[process.stderr])
    for stream in streams:
        assert stream is not None
        stream.close()
    return subprocess.CompletedProcess(
        argv,
        process.returncode,
        stdout.decode("utf-8", "replace"),
        stderr.decode("utf-8", "replace"),
    )


def git(
    repo: str | Path,
    *args: str,
    env: dict[str, str] | None = None,
    timeout: int = 120,
    check: bool = True,
) -> subprocess.CompletedProcess[str]:
    result = _bounded_process(
        ["git", "-C", str(repo), *args],
        env=env,
        timeout=timeout,
        output_limit=MAX_GIT_OUTPUT,
    )
    if check and result.returncode != 0:
        raise subprocess.CalledProcessError(
            result.returncode, result.args, output=result.stdout, stderr=result.stderr
        )
    return result


def atomic_write(path: Path, value: dict[str, Any]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, pending = tempfile.mkstemp(prefix=".pending-", dir=str(path.parent))
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as handle:
            json.dump(value, handle, sort_keys=True, separators=(",", ":"))
            handle.write("\n")
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(pending, path)
        directory_fd = os.open(path.parent, os.O_RDONLY)
        try:
            os.fsync(directory_fd)
        finally:
            os.close(directory_fd)
    finally:
        try:
            os.unlink(pending)
        except FileNotFoundError:
            pass


def read_json(path: Path) -> dict[str, Any] | None:
    """Read one JSON object, failing closed on anything unreadable.

    This is the entry point for resume state that may have been truncated,
    replaced, or hand-edited, so it must not raise. A very large file can raise
    MemoryError and a deeply nested document can raise RecursionError; neither
    derives from OSError or ValueError, so both used to escape and abort the
    process with a traceback before the corrupt-state handling could run.
    """
    try:
        raw = path.read_text(encoding="utf-8")
    except (OSError, ValueError, MemoryError):
        return None
    try:
        value = json.loads(raw)
    except (ValueError, RecursionError, MemoryError):
        return None
    return value if isinstance(value, dict) else None


def safe_path(value: Any) -> bool:
    if not isinstance(value, str) or not value or "\x00" in value:
        return False
    path = Path(value)
    return (
        not path.is_absolute()
        and ".." not in path.parts
        and ".git" not in path.parts
        and not value.startswith(".legion/")
    )


def _valid_content(value: Any) -> bool:
    if not isinstance(value, str) or not value.strip() or len(value) > 1000:
        return False
    if "\x00" in value or "<!-- legion-improve:" in value.lower():
        return False
    return not any(ord(char) < 32 and char not in "\n\t\r" for char in value)


def validate(proposal: Any) -> str | None:
    if not isinstance(proposal, dict) or proposal.get("schema") != PROPOSAL_SCHEMA:
        return "invalid_schema"
    allowed = {
        "schema",
        "id",
        "revision",
        "maintainer_eligible",
        "kind",
        "summary",
        "target",
        "candidate",
        "validation",
        "limits",
        "provenance",
    }
    if set(proposal) - allowed:
        return "invalid_schema"
    proposal_id = proposal.get("id")
    if not isinstance(proposal_id, str) or not re.fullmatch(
        r"[A-Za-z0-9][A-Za-z0-9._:-]{0,159}", proposal_id
    ):
        return "invalid_schema"
    if (
        not isinstance(proposal.get("revision"), int)
        or isinstance(proposal.get("revision"), bool)
        or proposal["revision"] < 1
    ):
        return "invalid_schema"
    summary = proposal.get("summary")
    if not isinstance(summary, str) or not summary.strip() or len(summary) > 1000:
        return "invalid_schema"
    if proposal.get("maintainer_eligible") is not True:
        return "not_maintainer_eligible"
    target = proposal.get("target")
    if (
        not isinstance(target, dict)
        or set(target) != {"path"}
        or not safe_path(target.get("path"))
        or not str(target.get("path", "")).endswith(".md")
        or proposal.get("kind") != "documentation_guardrail"
    ):
        return "path_not_allowlisted"
    candidate = proposal.get("candidate")
    if (
        not isinstance(candidate, dict)
        or set(candidate) != {"operation", "content"}
        or candidate.get("operation") != "append_markdown_guardrail"
        or not _valid_content(candidate.get("content"))
    ):
        return "mutation_not_allowlisted"
    validation = proposal.get("validation")
    if (
        not isinstance(validation, dict)
        or set(validation) != {"profile"}
        or validation.get("profile") != "documentation"
    ):
        return "validation_not_allowlisted"
    limits = proposal.get("limits", {})
    if limits is None:
        limits = {}
    if (
        not isinstance(limits, dict)
        or set(limits) - {"max_changed_lines"}
        or not isinstance(limits.get("max_changed_lines", 200), int)
        or isinstance(limits.get("max_changed_lines", 200), bool)
        or not 0 <= limits.get("max_changed_lines", 200) <= 500
    ):
        return "invalid_schema"
    provenance = proposal.get("provenance")
    # Evidence provenance is mandatory. This block used to be guarded by
    # `if provenance is not None`, so a proposal that simply omitted the key
    # skipped the documented eligibility bar entirely and was still schema
    # valid -- leaving the bar enforced only by whoever wrote the proposal and
    # never by the engine that acts on it. An engine that can open a pull
    # request must verify eligibility itself.
    if provenance is None:
        return "not_maintainer_eligible"
    if not isinstance(provenance, dict) or set(provenance) - {
        "source",
        "source_id",
        "law_key",
        "confidence",
        "support",
        "evidence_ids",
    }:
        return "invalid_schema"
    source = provenance.get("source", "")
    source_id = provenance.get("source_id")
    law_key = provenance.get("law_key")
    confidence = provenance.get("confidence")
    support = provenance.get("support")
    if not isinstance(source, str) or len(source) > 80:
        return "invalid_schema"
    if source_id is not None and (
        not isinstance(source_id, str) or len(source_id) > 160
    ):
        return "invalid_schema"
    if law_key is not None and (
        not isinstance(law_key, str)
        or not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._:-]{0,159}", law_key)
    ):
        return "invalid_schema"
    if confidence is not None and (
        not isinstance(confidence, (int, float))
        or isinstance(confidence, bool)
        or not math.isfinite(float(confidence))
        or not 0 <= confidence <= 1
    ):
        return "invalid_schema"
    if support is not None and (
        not isinstance(support, dict)
        or set(support) - {"episodes", "projects"}
        or any(
            not isinstance(value, int) or isinstance(value, bool) or value < 0
            for value in support.values()
        )
    ):
        return "invalid_schema"
    evidence_ids = provenance.get("evidence_ids", [])
    if (
        not isinstance(evidence_ids, list)
        or len(evidence_ids) > 20
        or not all(isinstance(item, str) and len(item) <= 160 for item in evidence_ids)
    ):
        return "invalid_schema"
    # An active cross-project learning law is the only evidence class that may
    # reach this engine. Anything else is rejected rather than skipping the bar
    # below, which is what an unrecognized or absent source used to do.
    if source != "learning-law":
        return "not_maintainer_eligible"
    if (
        not isinstance(law_key, str)
        or not law_key
        or
        not isinstance(confidence, (int, float))
        or isinstance(confidence, bool)
        or not math.isfinite(float(confidence))
        or confidence < 0.9
        or not isinstance(support, dict)
        or set(support) != {"episodes", "projects"}
        or not isinstance(support.get("episodes"), int)
        or isinstance(support.get("episodes"), bool)
        or support["episodes"] < 5
        or not isinstance(support.get("projects"), int)
        or isinstance(support.get("projects"), bool)
        or support["projects"] < 3
    ):
        return "not_maintainer_eligible"
    return None


def state_path(root: Path, fingerprint: str) -> Path:
    return root / "runs" / f"{fingerprint}.json"


def actual_worktree(root: Path, fingerprint: str, name: str = "candidate") -> Path:
    return root / "worktrees" / fingerprint / name


def public_worktree(fingerprint: str) -> str:
    return f"/isolated-worktree/{fingerprint}"


def _valid_sha(value: Any) -> bool:
    return isinstance(value, str) and bool(re.fullmatch(r"[0-9a-f]{40}|[0-9a-f]{64}", value))


def _valid_durable_record(
    record: Any, proposal: dict[str, Any], fingerprint: str
) -> bool:
    """Reject corrupt/tampered resume state before it can drive Git or GitHub."""
    if not isinstance(record, dict):
        return False
    allowed = {
        "schema", "mode", "proposal_id", "revision", "fingerprint", "state",
        "transitions", "reason", "remote_identity", "base_sha",
        "remote_base_sha", "base_branch", "base_source", "branch", "lease_id",
        "diff_digest", "changed_lines", "evaluation", "review_receipt", "draft_pr",
        "published_remote_head", "pending_rollback", "publish_attempt",
    }
    if set(record) - allowed:
        return False
    mode = record.get("mode")
    state = record.get("state")
    if not isinstance(mode, str) or not isinstance(state, str):
        return False
    if (
        record.get("schema") != RUN_SCHEMA
        or record.get("fingerprint") != fingerprint
        or record.get("proposal_id") != proposal["id"]
        or not isinstance(record.get("revision"), int)
        or isinstance(record.get("revision"), bool)
        or record["revision"] < 1
        or mode not in {"off", "dry-run", "draft"}
        or state not in set(STEPS) | TERMINAL
    ):
        return False
    reason = record.get("reason")
    if reason is not None and (not isinstance(reason, str) or len(reason) > 160):
        return False
    transitions = record.get("transitions", [])
    if not isinstance(transitions, list):
        return False
    active_transitions = (
        transitions[:-1]
        if state in {"rejected", "stale", "failed"}
        and transitions
        and transitions[-1] == state
        else transitions
    )
    if (
        not active_transitions
        or active_transitions != list(STEPS[: len(active_transitions)])
    ):
        return False
    if state in STEPS and transitions[-1] != state:
        return False
    if state in {"rejected", "stale", "failed"} and transitions[-1] != state:
        return False
    if "published_remote_head" in record and not _valid_sha(
        record.get("published_remote_head")
    ):
        return False
    pending_rollback = record.get("pending_rollback")
    if pending_rollback is not None:
        if (
            not isinstance(pending_rollback, dict)
            or set(pending_rollback)
            != {"id", "url", "repository", "head_branch", "head_sha"}
            or not isinstance(pending_rollback.get("repository"), str)
            or not re.fullmatch(
                r"[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+",
                pending_rollback.get("repository", ""),
            )
            or pending_rollback.get("head_branch") != record.get("branch")
            or not _valid_sha(pending_rollback.get("head_sha"))
            or pending_rollback.get("head_sha")
            != record.get("published_remote_head")
            or not re.fullmatch(
                rf"https://github\.com/{re.escape(pending_rollback.get('repository', ''))}/pull/[1-9][0-9]*",
                _safe_pr_url(str(pending_rollback.get("url") or "")),
            )
        ):
            return False
        pending_body = dict(pending_rollback)
        pending_id = pending_body.pop("id", None)
        if pending_id != digest(pending_body)[:24]:
            return False
    publish_attempt = record.get("publish_attempt")
    if publish_attempt is not None:
        if (
            not isinstance(publish_attempt, dict)
            or set(publish_attempt) - {
                "repository",
                "head_branch",
                "head_sha",
                "reconcile_attempts",
            }
            or not {"repository", "head_branch", "head_sha"} <= set(publish_attempt)
            or not isinstance(publish_attempt.get("repository"), str)
            or not re.fullmatch(
                r"[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+",
                publish_attempt.get("repository", ""),
            )
            or publish_attempt.get("head_branch") != record.get("branch")
            or not _valid_sha(publish_attempt.get("head_sha"))
        ):
            return False
        seen = publish_attempt.get("reconcile_attempts")
        # Bounded like every other durable counter. An unbounded value
        # would let hand-edited state skip the reconciliation wait in one
        # step and go straight to publishing.
        if seen is not None and (
            not isinstance(seen, int)
            or isinstance(seen, bool)
            or not 0 <= seen <= RECONCILE_ATTEMPTS
        ):
            return False
    if state == "eligible":
        return len(transitions) == 1

    snapshot_fields = (
        _valid_sha(record.get("remote_identity"))
        and _valid_sha(record.get("base_sha"))
        and _valid_sha(record.get("remote_base_sha"))
        and record.get("base_sha") == record.get("remote_base_sha")
        and record.get("base_source") in {"operator", "remote"}
        and isinstance(record.get("base_branch"), str)
        and bool(re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._/-]{0,159}", record["base_branch"]))
        and record.get("lease_id") == "lease-" + fingerprint[:20]
        and record.get("branch") == "legion-improve/" + fingerprint
    )
    # Early terminal records may be rejected before a lease is acquired.
    if not snapshot_fields:
        return (
            state in {"rejected", "failed"}
            and active_transitions == ["eligible"]
        )

    if len(active_transitions) >= 4:
        if (
            not _valid_sha(record.get("diff_digest"))
            or not isinstance(record.get("changed_lines"), int)
            or isinstance(record.get("changed_lines"), bool)
            or not 0 <= record["changed_lines"] <= 500
        ):
            return False
    if len(active_transitions) >= 5:
        evaluation = record.get("evaluation")
        if (
            not isinstance(evaluation, dict)
            or set(evaluation) != {"repeats", "checks", "baseline", "candidate"}
            or not isinstance(evaluation.get("repeats"), int)
            or not 2 <= evaluation["repeats"] <= 10
            or not isinstance(evaluation.get("checks"), int)
            or not 1 <= evaluation["checks"] <= 10
        ):
            return False
        rows = evaluation["baseline"], evaluation["candidate"]
        if any(
            not isinstance(group, list)
            or len(group) != evaluation["repeats"]
            or any(
                not isinstance(row, list)
                or len(row) != evaluation["checks"]
                or any(not isinstance(code, int) or isinstance(code, bool) for code in row)
                for row in group
            )
            for group in rows
        ):
            return False
    if len(active_transitions) >= 6:
        receipt = record.get("review_receipt")
        if (
            not isinstance(receipt, dict)
            or set(receipt)
            != {
                "schema", "id", "independent", "verdict", "reviewed_base_sha",
                "reviewed_head_sha", "diff_digest", "reviewer", "attempts",
            }
            or receipt.get("schema") != REVIEW_SCHEMA
            or receipt.get("independent") is not True
            or receipt.get("verdict") != "approved"
            or receipt.get("reviewed_base_sha") != record.get("base_sha")
            or not _valid_sha(receipt.get("reviewed_head_sha"))
            or receipt.get("diff_digest") != record.get("diff_digest")
            or not isinstance(receipt.get("reviewer"), dict)
            or set(receipt["reviewer"]) != {"kind", "model"}
            or receipt["reviewer"].get("kind") != "legion-delegate"
            or not isinstance(receipt["reviewer"].get("model"), str)
            or not re.fullmatch(
                r"[A-Za-z0-9][A-Za-z0-9._:/-]{0,95}",
                receipt["reviewer"]["model"],
            )
            or not isinstance(receipt.get("attempts"), int)
            or isinstance(receipt.get("attempts"), bool)
            or not 1 <= receipt["attempts"] <= 10
        ):
            return False
        receipt_body = dict(receipt)
        receipt_id = receipt_body.pop("id", None)
        if receipt_id != digest(receipt_body)[:24]:
            return False
    if state == "draft_created":
        draft_pr = record.get("draft_pr")
        if (
            transitions != list(STEPS)
            or not isinstance(draft_pr, dict)
            or set(draft_pr)
            != {
                "id", "draft", "url", "number", "body", "repository",
                "remote_identity", "base_branch", "base_sha", "head_branch",
                "head_sha",
            }
            or not isinstance(draft_pr.get("draft"), bool)
            or draft_pr.get("body") != IMPROVEMENT_PR_BODY
            or draft_pr.get("remote_identity") != record.get("remote_identity")
            or draft_pr.get("base_branch") != record.get("base_branch")
            or draft_pr.get("base_sha") != record.get("base_sha")
            or draft_pr.get("head_branch") != record.get("branch")
            or draft_pr.get("head_sha")
            != record["review_receipt"].get("reviewed_head_sha")
            or not isinstance(draft_pr.get("repository"), str)
            or not re.fullmatch(
                r"[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+",
                draft_pr.get("repository", ""),
            )
            or not isinstance(draft_pr.get("number"), int)
            or isinstance(draft_pr.get("number"), bool)
            or draft_pr.get("number", 0) < 1
            or not re.fullmatch(
                rf"https://github\.com/{re.escape(draft_pr.get('repository', ''))}/pull/{draft_pr.get('number')}",
                _safe_pr_url(str(draft_pr.get("url") or "")),
            )
        ):
            return False
        draft_body = dict(draft_pr)
        draft_id = draft_body.pop("id", None)
        if draft_id != digest(draft_body)[:24]:
            return False
    return True


def transition(record: dict[str, Any], state: str, **fields: Any) -> None:
    record["state"] = state
    record.update(fields)
    history = record.setdefault("transitions", [])
    if not history or history[-1] != state:
        history.append(state)


def terminal(record: dict[str, Any], state: str, reason: str) -> None:
    transition(record, state, reason=reason)


def _retryable_terminal(
    record: dict[str, Any], proposal: dict[str, Any], repo: str | Path
) -> bool:
    """Reopen only completed failures whose inputs or environment can recover."""
    if record.get("state") not in TERMINAL or record.get("state") == "draft_created":
        return False
    if proposal["revision"] > record.get("revision", 0):
        return True
    if record.get("state") == "stale":
        return True
    if record.get("reason") in TERMINAL_RETRYABLE_WITHOUT_INPUT_CHANGE:
        return True
    if _valid_sha(record.get("base_sha")):
        return _stale_reason(record, repo) is not None
    return False


def _remote_snapshot(repo: str | Path, base_ref: str = "") -> dict[str, str]:
    remote = git(repo, "remote", "get-url", "origin", check=False)
    if remote.returncode != 0 or not remote.stdout.strip():
        raise ImproveError("rejected", "remote_not_configured")
    base_source = "remote" if base_ref else "operator"
    if base_ref:
        if not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._/-]{0,159}", base_ref) or ".." in base_ref:
            raise ImproveError("rejected", "base_ref_invalid")
        remote_name, branch = "origin", base_ref
        head_sha = ""
    else:
        head = git(repo, "rev-parse", "HEAD^{commit}", check=False)
        upstream = git(
            repo,
            "rev-parse",
            "--abbrev-ref",
            "--symbolic-full-name",
            "@{upstream}",
            check=False,
        )
        if head.returncode != 0 or not head.stdout.strip():
            raise ImproveError("rejected", "base_sha_unavailable")
        upstream_name = upstream.stdout.strip()
        if upstream.returncode != 0 or "/" not in upstream_name:
            raise ImproveError("rejected", "upstream_not_configured")
        remote_name, branch = upstream_name.split("/", 1)
        head_sha = head.stdout.strip()
    remote_tip = git(
        repo,
        "ls-remote",
        "--exit-code",
        remote_name,
        f"refs/heads/{branch}",
        check=False,
    )
    if remote_tip.returncode != 0 or not remote_tip.stdout.strip():
        raise ImproveError("rejected", "remote_tip_unavailable")
    tip_sha = remote_tip.stdout.split()[0]
    if base_source == "remote":
        fetched = git(
            repo,
            "fetch",
            "--quiet",
            "--no-tags",
            remote_name,
            f"refs/heads/{branch}",
            check=False,
        )
        available = git(repo, "cat-file", "-e", f"{tip_sha}^{{commit}}", check=False)
        if fetched.returncode != 0 or available.returncode != 0:
            raise ImproveError("failed", "remote_base_fetch_failed")
        head_sha = tip_sha
    return {
        "remote_identity": hashlib.sha256(
            remote.stdout.strip().encode("utf-8")
        ).hexdigest(),
        "base_sha": head_sha,
        "remote_base_sha": tip_sha,
        "base_branch": branch,
        "base_source": base_source,
    }


def _stale_reason(record: dict[str, Any], repo: str | Path) -> str | None:
    try:
        current = _remote_snapshot(
            repo,
            str(record.get("base_branch") or "")
            if record.get("base_source") == "remote"
            else "",
        )
    except ImproveError:
        return "remote_identity_changed"
    for key, reason in (
        ("remote_identity", "remote_identity_changed"),
        ("base_branch", "base_branch_changed"),
        ("base_source", "base_source_changed"),
        ("base_sha", "base_sha_changed"),
        ("remote_base_sha", "remote_base_sha_changed"),
    ):
        if record.get(key) != current.get(key):
            return reason
    return None


def _repo_lock_path(repo: str | Path, fingerprint: str) -> Path:
    common = git(repo, "rev-parse", "--git-common-dir").stdout.strip()
    common_path = Path(common)
    if not common_path.is_absolute():
        common_path = Path(repo) / common_path
    lock_dir = common_path.resolve() / "legion-improve-locks"
    lock_dir.mkdir(parents=True, exist_ok=True)
    return lock_dir / f"{fingerprint}.lock"


def _git_common_dir(repo: str | Path) -> Path:
    common = Path(git(repo, "rev-parse", "--git-common-dir").stdout.strip())
    if not common.is_absolute():
        common = Path(repo) / common
    return common.resolve()


def ensure_worktree(
    repo: str | Path, root: Path, fingerprint: str, base: str, name: str
) -> Path:
    worktree = actual_worktree(root, fingerprint, name)
    valid = (
        worktree.exists()
        and git(worktree, "rev-parse", "--is-inside-work-tree", check=False).returncode
        == 0
    )
    if valid:
        try:
            valid = (
                Path(
                    git(worktree, "rev-parse", "--show-toplevel").stdout.strip()
                ).resolve()
                == worktree.resolve()
                and _git_common_dir(worktree) == _git_common_dir(repo)
            )
        except (OSError, subprocess.CalledProcessError):
            valid = False
    if valid:
        reset = git(worktree, "reset", "--hard", base, check=False)
        cleaned = git(worktree, "clean", "-ffdx", check=False)
        head = git(worktree, "rev-parse", "HEAD^{commit}", check=False)
        if (
            reset.returncode != 0
            or cleaned.returncode != 0
            or head.returncode != 0
            or head.stdout.strip() != base
        ):
            raise ImproveError("failed", "worktree_prepare_failed")
        return worktree
    if worktree.exists():
        git(repo, "worktree", "remove", "--force", str(worktree), check=False)
        shutil.rmtree(worktree, ignore_errors=True)
    worktree.parent.mkdir(parents=True, exist_ok=True)
    result = git(
        repo,
        "worktree",
        "add",
        "--quiet",
        "--detach",
        str(worktree),
        base,
        check=False,
    )
    if result.returncode != 0:
        raise ImproveError("failed", "worktree_prepare_failed")
    return worktree


def cleanup_worktrees(repo: str | Path, root: Path, fingerprint: str) -> None:
    for name in ("baseline", "candidate"):
        worktree = actual_worktree(root, fingerprint, name)
        git(repo, "worktree", "remove", "--force", str(worktree), check=False)
        if worktree.exists():
            shutil.rmtree(worktree, ignore_errors=True)
    git(repo, "worktree", "prune", check=False)


def _target_file(worktree: Path, relative: str) -> Path:
    target = worktree / relative
    if target.is_symlink() or not target.is_file():
        raise ImproveError("failed", "candidate_target_unavailable")
    try:
        target.resolve(strict=True).relative_to(worktree.resolve(strict=True))
    except (OSError, ValueError):
        raise ImproveError("rejected", "path_not_allowlisted") from None
    if target.stat().st_size > MAX_SOURCE_BYTES:
        raise ImproveError("rejected", "candidate_target_too_large")
    return target


def _plugin_policy_paths(worktree: Path, relative: str) -> list[str]:
    """Derive policy-mandated version files from a Markdown target."""
    target = worktree / relative
    for parent in (target.parent, *target.parents):
        if parent == worktree or worktree not in parent.parents:
            break
        manifest = parent / ".claude-plugin" / "plugin.json"
        if not manifest.is_file():
            continue
        marketplace = worktree / ".claude-plugin" / "marketplace.json"
        if not marketplace.is_file():
            raise ImproveError("rejected", "plugin_version_policy_unavailable")
        return sorted(
            {
                relative,
                manifest.relative_to(worktree).as_posix(),
                marketplace.relative_to(worktree).as_posix(),
            }
        )
    return [relative]


def _write_pretty_json(path: Path, value: dict[str, Any]) -> None:
    fd, pending = tempfile.mkstemp(prefix=".legion-improve-json-", dir=str(path.parent))
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as handle:
            json.dump(value, handle, indent=2, ensure_ascii=False)
            handle.write("\n")
            handle.flush()
            os.fsync(handle.fileno())
        os.chmod(pending, path.stat().st_mode)
        os.replace(pending, path)
    finally:
        try:
            os.unlink(pending)
        except FileNotFoundError:
            pass


def _sync_plugin_policy_versions(worktree: Path, relative: str) -> None:
    policy_paths = _plugin_policy_paths(worktree, relative)
    if len(policy_paths) == 1:
        return
    manifest_rel = next(path for path in policy_paths if path.endswith("/.claude-plugin/plugin.json"))
    marketplace_rel = ".claude-plugin/marketplace.json"
    manifest_path = worktree / manifest_rel
    marketplace_path = worktree / marketplace_rel
    manifest = read_json(manifest_path)
    marketplace = read_json(marketplace_path)
    if not isinstance(manifest, dict) or not isinstance(marketplace, dict):
        raise ImproveError("rejected", "plugin_version_policy_unavailable")
    version = manifest.get("version")
    match = re.fullmatch(r"(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)", str(version or ""))
    name = manifest.get("name")
    plugins = marketplace.get("plugins")
    if not match or not isinstance(name, str) or not isinstance(plugins, list):
        raise ImproveError("rejected", "plugin_version_policy_unavailable")
    next_version = f"{match.group(1)}.{match.group(2)}.{int(match.group(3)) + 1}"
    matches = [item for item in plugins if isinstance(item, dict) and item.get("name") == name]
    if len(matches) != 1 or matches[0].get("version") != version:
        raise ImproveError("rejected", "plugin_version_policy_unavailable")
    manifest["version"] = next_version
    matches[0]["version"] = next_version
    _write_pretty_json(manifest_path, manifest)
    _write_pretty_json(marketplace_path, marketplace)


def apply_candidate(
    record: dict[str, Any], proposal: dict[str, Any], root: Path
) -> None:
    worktree = actual_worktree(root, record["fingerprint"])
    # Rebuild from the frozen base before every attempt. This closes the crash
    # window between mutating the candidate and persisting candidate_ready.
    reset = git(worktree, "reset", "--hard", record["base_sha"], check=False)
    if reset.returncode != 0:
        raise ImproveError("failed", "candidate_reset_failed")
    # reset --hard restores tracked content but leaves untracked files behind.
    # A temp file orphaned by a crash mid-write is later picked up by
    # `ls-files --others` and rejects the proposal as path_not_allowlisted --
    # a terminal state that does not reopen without an input change. Clean the
    # tree the same way ensure_worktree does.
    cleaned = git(worktree, "clean", "-ffdx", check=False)
    if cleaned.returncode != 0:
        raise ImproveError("failed", "candidate_reset_failed")
    relative = proposal["target"]["path"]
    target = _target_file(worktree, relative)
    try:
        original = target.read_text(encoding="utf-8")
    except UnicodeError:
        raise ImproveError("failed", "candidate_target_invalid_utf8") from None
    content = re.sub(r"\s+", " ", proposal["candidate"]["content"]).strip()
    marker = digest({"proposal_id": proposal["id"]})[:16]
    start = f"<!-- legion-improve:{marker}:start -->"
    end = f"<!-- legion-improve:{marker}:end -->"
    block = f"{start}\n## Learned Guardrail\n\n- {content}\n{end}"
    pattern = re.compile(
        rf"\n?{re.escape(start)}.*?{re.escape(end)}\n?", re.DOTALL
    )
    if pattern.search(original):
        updated = pattern.sub("\n\n" + block + "\n", original).rstrip() + "\n"
    else:
        updated = original.rstrip() + "\n\n" + block + "\n"
    fd, pending = tempfile.mkstemp(prefix=".legion-improve-", dir=str(target.parent))
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as handle:
            handle.write(updated)
            handle.flush()
            os.fsync(handle.fileno())
        os.chmod(pending, target.stat().st_mode)
        os.replace(pending, target)
        _sync_plugin_policy_versions(worktree, relative)
    finally:
        try:
            os.unlink(pending)
        except FileNotFoundError:
            pass


def changed_paths(worktree: Path) -> tuple[list[str], int, str]:
    """Summarize the working-tree change as (paths, changed lines, diff digest).

    Every git call here is checked, because _bounded_process returns an *empty*
    stdout when a command exceeds its output cap. An empty diff hashes to
    EMPTY_DIFF, which is the sentinel meaning "nothing changed" -- so an
    unchecked failure would report a large real mutation as no mutation and
    defeat the baseline tamper check that consumes this digest.
    """
    listed = git(worktree, "diff", "--name-only", "HEAD", "--", check=False)
    others = git(
        worktree, "ls-files", "--others", "--exclude-standard", check=False
    )
    stats = git(worktree, "diff", "--numstat", "HEAD", "--", check=False)
    diffed = git(worktree, "diff", "--binary", "HEAD", "--", check=False)
    if any(
        result.returncode != 0 for result in (listed, others, stats, diffed)
    ):
        raise ImproveError("failed", "changed_paths_unavailable")
    names = listed.stdout.splitlines()
    names.extend(others.stdout.splitlines())
    changed_lines = 0
    for row in stats.stdout.splitlines():
        columns = row.split("\t")
        if len(columns) >= 2 and columns[0].isdigit() and columns[1].isdigit():
            changed_lines += int(columns[0]) + int(columns[1])
    patch = diffed.stdout.encode("utf-8")
    return sorted(set(names)), changed_lines, hashlib.sha256(patch).hexdigest()


def _evaluation_code(worktree: Path, target: str) -> tuple[int, ...]:
    codes = [
        git(worktree, "diff", "--check", "HEAD", "--", target, check=False).returncode
    ]
    doctor = worktree / "legion-observability" / "bin" / "legion-doctor"
    if doctor.is_file() and os.access(doctor, os.X_OK):
        codes.append(
            _bounded_process(
                [str(doctor), "--repo", str(worktree)], cwd=worktree, timeout=300
            ).returncode
        )
    configured = os.environ.get("LEGION_IMPROVE_VALIDATOR_BIN", "").strip()
    if configured:
        validator = shutil.which(configured) if not os.path.isabs(configured) else configured
        if not validator or not os.access(validator, os.X_OK):
            codes.append(127)
        else:
            codes.append(
                _bounded_process(
                    [validator, target], cwd=worktree, timeout=120
                ).returncode
            )
    return tuple(codes)


def evaluate(
    record: dict[str, Any], proposal: dict[str, Any], root: Path, repeats: int
) -> str | None:
    candidate = actual_worktree(root, record["fingerprint"])
    baseline = ensure_worktree(
        record["repo_runtime"],
        root,
        record["fingerprint"],
        record["base_sha"],
        "baseline",
    )
    target = proposal["target"]["path"]
    baseline_results: list[tuple[int, ...]] = []
    candidate_results: list[tuple[int, ...]] = []
    for _ in range(repeats):
        baseline_results.append(_evaluation_code(baseline, target))
        if changed_paths(baseline)[2] != EMPTY_DIFF:
            return "baseline_mutated"
    expected = record["diff_digest"]
    for _ in range(repeats):
        candidate_results.append(_evaluation_code(candidate, target))
        if changed_paths(candidate)[2] != expected:
            return "candidate_mutated"
    if len(set(baseline_results)) > 1:
        return "baseline_variance"
    if len(set(candidate_results)) > 1:
        return "candidate_variance"
    if any(code != 0 for result in baseline_results for code in result):
        return "baseline_failed"
    if any(code != 0 for result in candidate_results for code in result):
        return "regression"
    record["evaluation"] = {
        "repeats": repeats,
        "checks": len(baseline_results[0]),
        "baseline": [list(item) for item in baseline_results],
        "candidate": [list(item) for item in candidate_results],
    }
    return None


def create_candidate_snapshot(
    record: dict[str, Any], proposal: dict[str, Any], root: Path
) -> str:
    candidate = actual_worktree(root, record["fingerprint"])
    root.mkdir(parents=True, exist_ok=True)
    fd, index_name = tempfile.mkstemp(prefix="review-index-", dir=str(root))
    os.close(fd)
    os.unlink(index_name)
    index = Path(index_name)
    env = dict(os.environ)
    env.update(
        {
            "GIT_INDEX_FILE": str(index),
            "GIT_AUTHOR_NAME": "Legion Improve",
            "GIT_AUTHOR_EMAIL": "legion@local",
            "GIT_COMMITTER_NAME": "Legion Improve",
            "GIT_COMMITTER_EMAIL": "legion@local",
            "GIT_AUTHOR_DATE": "2000-01-01T00:00:00Z",
            "GIT_COMMITTER_DATE": "2000-01-01T00:00:00Z",
        }
    )
    try:
        git(candidate, "read-tree", record["base_sha"], env=env)
        git(
            candidate,
            "add",
            "--",
            *_plugin_policy_paths(candidate, proposal["target"]["path"]),
            env=env,
        )
        tree_sha = git(candidate, "write-tree", env=env).stdout.strip()
        created = _bounded_process(
            [
                "git",
                "-C",
                str(candidate),
                "commit-tree",
                tree_sha,
                "-p",
                record["base_sha"],
            ],
            env=env,
            timeout=120,
        )
        if created.returncode != 0 or not created.stdout.strip():
            raise ImproveError("failed", "review_snapshot_failed")
        head_sha = created.stdout.strip()
    finally:
        index.unlink(missing_ok=True)
        Path(str(index) + ".lock").unlink(missing_ok=True)
    patch = git(
        candidate,
        "diff",
        "--binary",
        record["base_sha"],
        head_sha,
        "--",
        check=False,
    ).stdout.encode("utf-8")
    if hashlib.sha256(patch).hexdigest() != record["diff_digest"]:
        raise ImproveError("failed", "review_snapshot_mismatch")
    return head_sha


def independent_review(
    record: dict[str, Any], proposal: dict[str, Any], root: Path
) -> None:
    head_sha = create_candidate_snapshot(record, proposal, root)
    configured = os.environ.get("LEGION_IMPROVE_REVIEW_BIN", "legion-delegate")
    reviewer = _resolve_command(configured)
    if not reviewer or not os.access(reviewer, os.X_OK):
        raise ImproveError("failed", "independent_review_unavailable")
    result = _bounded_process(
        [
            reviewer,
            "review",
            "--repo",
            str(actual_worktree(root, record["fingerprint"])),
            "--base",
            record["base_sha"],
            "--head",
            head_sha,
            "--max-attempts",
            "2",
            "--quiet",
        ],
        timeout=900,
    )
    if result.returncode != 0:
        raise ImproveError("failed", "independent_review_failed")
    try:
        payload = json.loads(result.stdout)
    except (TypeError, ValueError):
        raise ImproveError("failed", "independent_review_invalid") from None
    if (
        not isinstance(payload, dict)
        or payload.get("status") != "ok"
        or payload.get("reviewed_base_sha") != record["base_sha"]
        or payload.get("reviewed_head_sha") != head_sha
        or not isinstance(payload.get("model"), str)
        or not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._:/-]{0,95}", payload["model"])
    ):
        raise ImproveError("failed", "independent_review_invalid")
    verdict = payload.get("verdict")
    if not isinstance(verdict, dict) or verdict.get("verdict") not in {
        "approve",
        "request_changes",
    }:
        raise ImproveError("failed", "independent_review_invalid")
    findings = verdict.get("findings", [])
    if not isinstance(findings, list):
        raise ImproveError("failed", "independent_review_invalid")
    blocked_finding = any(
        isinstance(item, dict)
        and str(item.get("severity", "")).lower() in {"critical", "high", "medium"}
        for item in findings
    )
    if verdict["verdict"] != "approve" or blocked_finding:
        raise ImproveError("rejected", "review_requested_changes")
    attempts = payload.get("attempts", 1)
    if not isinstance(attempts, int) or not 1 <= attempts <= 10:
        raise ImproveError("failed", "independent_review_invalid")
    receipt = {
        "schema": REVIEW_SCHEMA,
        "independent": True,
        "verdict": "approved",
        "reviewed_base_sha": record["base_sha"],
        "reviewed_head_sha": head_sha,
        "diff_digest": record["diff_digest"],
        "reviewer": {"kind": "legion-delegate", "model": payload["model"]},
        "attempts": attempts,
    }
    receipt["id"] = digest(receipt)[:24]
    record["review_receipt"] = receipt


def _remote_branch_sha(worktree: Path, branch: str) -> str:
    result = git(
        worktree,
        "ls-remote",
        "--exit-code",
        "origin",
        f"refs/heads/{branch}",
        check=False,
    )
    return result.stdout.split()[0] if result.returncode == 0 and result.stdout else ""


def _reviewed_head_matches(
    record: dict[str, Any], proposal: dict[str, Any], root: Path
) -> bool:
    """Recheck the immutable reviewed commit before any external publication."""
    worktree = actual_worktree(root, record["fingerprint"])
    base = record["base_sha"]
    head = record["review_receipt"]["reviewed_head_sha"]
    parents = git(worktree, "rev-list", "--parents", "-n", "1", head, check=False)
    if parents.returncode != 0 or parents.stdout.split() != [head, base]:
        return False
    paths = git(
        worktree, "diff", "--name-only", base, head, "--", check=False
    )
    expected_paths = _plugin_policy_paths(worktree, proposal["target"]["path"])
    if paths.returncode != 0 or sorted(paths.stdout.splitlines()) != expected_paths:
        return False
    patch = git(
        worktree, "diff", "--binary", base, head, "--", check=False
    )
    if patch.returncode != 0:
        return False
    return hashlib.sha256(patch.stdout.encode("utf-8")).hexdigest() == record["diff_digest"]


def _safe_pr_url(value: str) -> str:
    value = value.strip()[:512]
    return value if re.fullmatch(r"https://[^\s]+", value) else ""


def _github_repository(worktree: Path) -> str:
    configured = os.environ.get("LEGION_IMPROVE_GITHUB_REPOSITORY", "").strip()
    if configured:
        return (
            configured
            if re.fullmatch(r"[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+", configured)
            else ""
        )
    remote = git(worktree, "remote", "get-url", "origin", check=False)
    value = remote.stdout.strip()
    match = re.fullmatch(
        r"(?:https://github\.com/|ssh://git@github\.com/|git@github\.com:)([A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+?)(?:\.git)?/?",
        value,
    )
    return match.group(1) if match else ""


def _draft_pr_payload(
    row: dict[str, Any], record: dict[str, Any], repository: str
) -> dict[str, Any] | None:
    number = row.get("number")
    url = _safe_pr_url(str(row.get("url") or ""))
    if (
        not repository
        or not isinstance(number, int)
        or isinstance(number, bool)
        or number < 1
        or row.get("body") != IMPROVEMENT_PR_BODY
        or not re.fullmatch(
            rf"https://github\.com/{re.escape(repository)}/pull/{number}", url
        )
    ):
        return None
    payload = {
        "draft": row.get("isDraft") is True,
        "url": url,
        "number": number,
        "body": row["body"],
        "repository": repository,
        "remote_identity": record["remote_identity"],
        "base_branch": record["base_branch"],
        "base_sha": record["base_sha"],
        "head_branch": record["branch"],
        "head_sha": record["review_receipt"]["reviewed_head_sha"],
    }
    payload["id"] = digest(payload)[:24]
    return payload


def _pr_identity_error(
    row: Any,
    record: dict[str, Any],
    branch: str,
    head_sha: str,
    *,
    require_draft: bool = True,
) -> str | None:
    if not isinstance(row, dict):
        return "existing_pr_identity_mismatch"
    # Deliberately state-blind. Reusing an already closed or merged pull request
    # for the deterministic head is the documented behavior: the alternative is
    # opening a duplicate of the very change a maintainer already decided on.
    # See docs/self-learning.md and
    # test_closed_or_merged_publication_is_reused_without_duplicate_pr.
    if require_draft and row.get("isDraft") is not True:
        return "existing_pr_not_draft"
    if row.get("body") != IMPROVEMENT_PR_BODY:
        return "existing_pr_body_mismatch"
    if (
        row.get("baseRefName") != record["base_branch"]
        or row.get("baseRefOid") != record["base_sha"]
        or row.get("headRefName") != branch
        or row.get("headRefOid") != head_sha
    ):
        return "existing_pr_identity_mismatch"
    if not _safe_pr_url(str(row.get("url") or "")):
        return "existing_pr_identity_mismatch"
    return None


def _delete_owned_remote_branch(
    worktree: Path, branch: str, expected_head: str
) -> bool:
    current = _remote_branch_sha(worktree, branch)
    if not current:
        return True
    if current != expected_head:
        return False
    deleted = git(
        worktree,
        "push",
        "--quiet",
        f"--force-with-lease=refs/heads/{branch}:{expected_head}",
        "origin",
        f":refs/heads/{branch}",
        check=False,
    )
    return deleted.returncode == 0 or not _remote_branch_sha(worktree, branch)


def _rollback_created_pr(
    gh: str, worktree: Path, pr_url: str, branch: str, head_sha: str
) -> bool:
    closed = _bounded_process(
        [gh, "pr", "close", pr_url, "--delete-branch"],
        cwd=worktree,
        timeout=120,
    )
    closed_or_already_closed = closed.returncode == 0
    if not closed_or_already_closed:
        viewed = _bounded_process(
            [gh, "pr", "view", pr_url, "--json", "state"],
            cwd=worktree,
            timeout=120,
        )
        try:
            state = json.loads(viewed.stdout).get("state")
        except (AttributeError, ValueError):
            state = ""
        closed_or_already_closed = viewed.returncode == 0 and state == "CLOSED"
    branch_removed = _delete_owned_remote_branch(worktree, branch, head_sha)
    return closed_or_already_closed and branch_removed


def _pending_rollback_payload(
    pr_url: str, repository: str, branch: str, head_sha: str
) -> dict[str, str] | None:
    url = _safe_pr_url(pr_url)
    if not re.fullmatch(
        rf"https://github\.com/{re.escape(repository)}/pull/[1-9][0-9]*", url
    ):
        return None
    payload = {
        "url": url,
        "repository": repository,
        "head_branch": branch,
        "head_sha": head_sha,
    }
    return {"id": digest(payload)[:24], **payload}


def _owned_open_draft(
    row: Any, repository: str, branch: str, head_sha: str
) -> dict[str, str] | None:
    number = row.get("number") if isinstance(row, dict) else None
    url = _safe_pr_url(str(row.get("url") or "")) if isinstance(row, dict) else ""
    if (
        not isinstance(row, dict)
        or not isinstance(number, int)
        or isinstance(number, bool)
        or number < 1
        or not re.fullmatch(
            rf"https://github\.com/{re.escape(repository)}/pull/{number}", url
        )
        or row.get("state") != "OPEN"
        or row.get("isDraft") is not True
        or row.get("body") != IMPROVEMENT_PR_BODY
        or row.get("headRefName") != branch
        or row.get("headRefOid") != head_sha
    ):
        return None
    return _pending_rollback_payload(url, repository, branch, head_sha)


def _persist_draft_state(root: Path, record: dict[str, Any]) -> None:
    atomic_write(state_path(root, record["fingerprint"]), record)


def _finish_pending_rollback(
    record: dict[str, Any], root: Path, gh: str, worktree: Path
) -> bool:
    pending = record.get("pending_rollback")
    if not isinstance(pending, dict):
        return True
    rolled_back = _rollback_created_pr(
        gh,
        worktree,
        pending["url"],
        pending["head_branch"],
        pending["head_sha"],
    )
    if rolled_back:
        record.pop("pending_rollback", None)
        if record.get("published_remote_head") == pending["head_sha"]:
            record.pop("published_remote_head", None)
        _persist_draft_state(root, record)
    return rolled_back


def draft(
    record: dict[str, Any],
    proposal: dict[str, Any],
    root: Path,
    source_repo: str | Path,
) -> str | None:
    pending = record.get("pending_rollback")
    # A pre-fix run may have removed its candidate worktree after persisting a
    # rollback receipt. Roll back from the operator repository so recovery does
    # not depend on recreating the reviewed candidate checkout.
    operation_repo = (
        Path(source_repo).resolve()
        if pending
        else actual_worktree(root, record["fingerprint"])
    )
    gh_configured = os.environ.get("GH_BIN", "gh")
    gh = shutil.which(gh_configured) if not os.path.isabs(gh_configured) else gh_configured
    if not gh or not os.access(gh, os.X_OK):
        return "gh_unavailable"
    repository = _github_repository(operation_repo)
    if not repository:
        return "gh_unavailable"
    if pending:
        if pending.get("repository") != repository:
            return "draft_pr_rollback_failed"
        if not _finish_pending_rollback(record, root, gh, operation_repo):
            return "draft_pr_rollback_failed"
        return (
            "draft_base_changed"
            if _stale_reason(record, source_repo) is not None
            else "draft_pr_rolled_back"
        )
    worktree = operation_repo
    if not _reviewed_head_matches(record, proposal, root):
        return "review_snapshot_mismatch"
    head_sha = record["review_receipt"]["reviewed_head_sha"]
    branch = record["branch"]
    # A local deterministic ref is safe and lets identity probes resolve the
    # reviewed head without publishing or moving any remote state.
    git(worktree, "branch", "--force", branch, head_sha, check=False)
    listed = _bounded_process(
        [
            gh,
            "pr",
            "list",
            "--head",
            branch,
            "--state",
            "all",
            "--json",
            "number,url,state,isDraft,body,baseRefName,baseRefOid,headRefName,headRefOid",
        ],
        cwd=worktree,
        timeout=120,
    )
    pr_url = ""
    if listed.returncode != 0:
        return "draft_pr_list_failed"
    try:
        rows = json.loads(listed.stdout or "[]")
    except ValueError:
        return "draft_pr_list_failed"
    if not isinstance(rows, list):
        return "draft_pr_list_failed"
    if rows:
        if len(rows) != 1:
            return "existing_pr_already_published"
        existing_pr = rows[0]
        identity_error = _pr_identity_error(
            existing_pr,
            record,
            branch,
            head_sha,
            require_draft=False,
        )
        if identity_error:
            owned = _owned_open_draft(existing_pr, repository, branch, head_sha)
            if owned:
                record["published_remote_head"] = head_sha
                record["pending_rollback"] = owned
                _persist_draft_state(root, record)
                return (
                    identity_error
                    if _finish_pending_rollback(record, root, gh, worktree)
                    else "draft_pr_rollback_failed"
                )
            return "existing_pr_already_published"
        pr_url = _safe_pr_url(str(existing_pr.get("url") or ""))
        draft_pr = _draft_pr_payload(existing_pr, record, repository)
        if draft_pr is None:
            return "existing_pr_identity_mismatch"
        record["draft_pr"] = draft_pr
        record["published_remote_head"] = head_sha
        record.pop("publish_attempt", None)
        _persist_draft_state(root, record)
        return None

    # An empty listing is not proof that nothing was published. If an earlier
    # attempt recorded a publish intent for this exact head, GitHub's list
    # consistency window can hide a pull request that really exists, and
    # creating another here is precisely the duplicate the intent record exists
    # to prevent.
    #
    # The wait is bounded. A crash before `gh pr create` ever ran, or a create
    # that genuinely failed, leaves an intent that no listing will ever
    # corroborate; blocking on it forever would wedge this fingerprint with no
    # way out but hand-editing state. After RECONCILE_ATTEMPTS consecutive
    # empty listings -- far longer than any list-consistency window, since runs
    # are daily -- conclude nothing was published and allow the retry.
    attempt = record.get("publish_attempt")
    if (
        isinstance(attempt, dict)
        and attempt.get("repository") == repository
        and attempt.get("head_branch") == branch
        and attempt.get("head_sha") == head_sha
    ):
        seen = attempt.get("reconcile_attempts")
        seen = seen + 1 if isinstance(seen, int) and not isinstance(seen, bool) else 1
        if seen < RECONCILE_ATTEMPTS:
            attempt = dict(attempt)
            attempt["reconcile_attempts"] = seen
            record["publish_attempt"] = attempt
            _persist_draft_state(root, record)
            return "draft_pr_reconcile_pending"
        record.pop("publish_attempt", None)
        _persist_draft_state(root, record)

    existing = _remote_branch_sha(worktree, branch)
    if existing and existing != head_sha:
        published = record.get("published_remote_head")
        if not _valid_sha(published) or existing != published:
            return "branch_collision"
        pushed = git(
            worktree,
            "push",
            "--quiet",
            f"--force-with-lease=refs/heads/{branch}:{published}",
            "origin",
            f"{head_sha}:refs/heads/{branch}",
            check=False,
        )
        if pushed.returncode != 0 and _remote_branch_sha(worktree, branch) != head_sha:
            return "branch_push_failed"
    elif not existing:
        pushed = git(
            worktree,
            "push",
            "--quiet",
            "origin",
            f"{head_sha}:refs/heads/{branch}",
            check=False,
        )
        if pushed.returncode != 0 and _remote_branch_sha(worktree, branch) != head_sha:
            return "branch_push_failed"
    record["published_remote_head"] = head_sha
    _persist_draft_state(root, record)
    if not pr_url:
        if _stale_reason(record, source_repo) is not None:
            if not _delete_owned_remote_branch(worktree, branch, head_sha):
                return "draft_pr_rollback_failed"
            record.pop("published_remote_head", None)
            _persist_draft_state(root, record)
            return "draft_base_changed"
        # Record the intent to publish before the one irreversible call in this
        # engine. If `gh pr create` succeeds but this process dies before the
        # rollback receipt is persisted -- or prints a banner line where the URL
        # was expected -- the durable record would otherwise hold no trace of a
        # real pull request, and a later run could open a second one for the
        # same fingerprint.
        record["publish_attempt"] = {
            "repository": repository,
            "head_branch": branch,
            "head_sha": head_sha,
        }
        _persist_draft_state(root, record)
        created = _bounded_process(
            [
                gh,
                "pr",
                "create",
                "--draft",
                "--base",
                record["base_branch"],
                "--head",
                branch,
                "--title",
                f"docs: review improvement {record['fingerprint'][:12]}",
                "--body",
                IMPROVEMENT_PR_BODY,
            ],
            cwd=worktree,
            timeout=120,
        )
        if created.returncode != 0:
            # A rejection by gh means no pull request exists and a straight
            # retry is safe. A local timeout or an output-cap kill does NOT
            # mean that: _bounded_process synthesizes those codes after killing
            # the child, while the request it already sent can still land at
            # GitHub. Those keep the intent so the next run reconciles instead
            # of opening a duplicate.
            if created.returncode not in _AMBIGUOUS_PROCESS_CODES:
                record.pop("publish_attempt", None)
                _persist_draft_state(root, record)
            return "draft_pr_create_failed"
        lines = created.stdout.strip().splitlines()
        pr_url = _safe_pr_url(lines[-1] if lines else "")
        if not pr_url:
            return "draft_pr_response_invalid"
        pending = _pending_rollback_payload(pr_url, repository, branch, head_sha)
        if pending is None:
            return "draft_pr_response_invalid"
        record["pending_rollback"] = pending
        _persist_draft_state(root, record)
        verified = _bounded_process(
            [
                gh,
                "pr",
                "view",
                pr_url,
                "--json",
                "number,url,state,isDraft,body,baseRefName,baseRefOid,headRefName,headRefOid",
            ],
            cwd=worktree,
            timeout=120,
        )
        if verified.returncode != 0:
            return (
                "draft_pr_verify_failed"
                if _finish_pending_rollback(record, root, gh, worktree)
                else "draft_pr_rollback_failed"
            )
        try:
            created_pr = json.loads(verified.stdout)
        except ValueError:
            return (
                "draft_pr_verify_failed"
                if _finish_pending_rollback(record, root, gh, worktree)
                else "draft_pr_rollback_failed"
            )
        identity_error = _pr_identity_error(
            created_pr, record, branch, head_sha
        )
        created_payload = _draft_pr_payload(created_pr, record, repository)
        if identity_error or created_payload is None or _stale_reason(record, source_repo) is not None:
            failure = identity_error or "draft_base_changed"
            return (
                failure
                if _finish_pending_rollback(record, root, gh, worktree)
                else "draft_pr_rollback_failed"
            )
        record["draft_pr"] = created_payload
        record.pop("pending_rollback", None)
        record.pop("publish_attempt", None)
        _persist_draft_state(root, record)
    return None


def public(record: dict[str, Any]) -> dict[str, Any]:
    keys = (
        "mode",
        "proposal_id",
        "revision",
        "fingerprint",
        "state",
        "reason",
        "remote_identity",
        "base_sha",
        "remote_base_sha",
        "base_branch",
        "base_source",
        "branch",
        "lease_id",
        "published_remote_head",
        "pending_rollback",
        "publish_attempt",
        "review_receipt",
        "draft_pr",
    )
    value: dict[str, Any] = {"schema": RUN_SCHEMA}
    for key in keys:
        if key in record and record[key] not in (None, ""):
            value[key] = record[key]
    state = record.get("state")
    if state in STEPS:
        value["transitions"] = list(record.get("transitions", []))
    if (
        state in STEPS
        and STEPS.index(state) >= STEPS.index("prepared")
        or state not in STEPS
        and bool(record.get("branch"))
    ):
        value["worktree"] = public_worktree(record["fingerprint"])
    return value


def error_payload(command: str, reason: str) -> dict[str, Any]:
    return {
        "schema": ERROR_SCHEMA,
        "command": command,
        "status": "error",
        "reason": reason,
    }


def maybe_stop(record: dict[str, Any], stop_after: str | None) -> None:
    if stop_after == record.get("state"):
        raise ImproveError(record["state"], "stopped_for_resume_test")


def _initial_record(
    proposal: dict[str, Any], fingerprint: str, mode: str
) -> dict[str, Any]:
    return {
        "schema": RUN_SCHEMA,
        "mode": mode,
        "proposal_id": proposal["id"],
        "revision": proposal["revision"],
        "fingerprint": fingerprint,
        "state": "eligible",
        "transitions": ["eligible"],
    }


def execute(args: argparse.Namespace) -> tuple[int, dict[str, Any]]:
    proposal = _read_proposal(Path(args.proposal))
    fingerprint = digest(proposal if proposal is not None else {"proposal": "unreadable"})
    reason = validate(proposal)
    if reason:
        raw_id = proposal.get("id", "") if isinstance(proposal, dict) else ""
        raw_revision = (
            proposal.get("revision", 0) if isinstance(proposal, dict) else 0
        )
        record = {
            "schema": RUN_SCHEMA,
            "mode": args.mode,
            "proposal_id": raw_id if isinstance(raw_id, str) else "",
            "revision": (
                raw_revision
                if isinstance(raw_revision, int) and not isinstance(raw_revision, bool)
                else 0
            ),
            "fingerprint": fingerprint,
            "state": "rejected",
            "reason": reason,
        }
        return 2, public(record)
    assert isinstance(proposal, dict)
    fingerprint = proposal_fingerprint(proposal)
    if args.mode == "off":
        return 0, public(_initial_record(proposal, fingerprint, "off"))

    root = Path(args.state_dir).resolve()
    try:
        lock_path = _repo_lock_path(args.repo, fingerprint)
    except (OSError, subprocess.CalledProcessError):
        record = _initial_record(proposal, fingerprint, args.mode)
        terminal(record, "rejected", "repository_unavailable")
        return 2, public(record)
    with open(lock_path, "a+", encoding="utf-8") as lock:
        fcntl.flock(lock.fileno(), fcntl.LOCK_EX)
        path = state_path(root, fingerprint)
        if path.exists():
            record = read_json(path)
            if not _valid_durable_record(record, proposal, fingerprint):
                corrupt = _initial_record(proposal, fingerprint, args.mode)
                terminal(corrupt, "failed", "state_corrupt")
                atomic_write(path, corrupt)
                return 2, public(corrupt)
        else:
            record = _initial_record(proposal, fingerprint, args.mode)
        if (
            record.get("state") in {"rejected", "stale", "failed"}
            and record.get("pending_rollback")
            and record.get("transitions", [])[-2:]
            == ["reviewed", record.get("state")]
        ):
            # A process-level failure after draft creation must not discard the
            # durable rollback receipt. Re-enter the reviewed cleanup boundary
            # before ordinary terminal retry handling can reset the record.
            record["state"] = "reviewed"
            record["transitions"].pop()
            record["reason"] = "draft_pr_rollback_failed"
            atomic_write(path, record)
        if record.get("state") in TERMINAL:
            if not _retryable_terminal(record, proposal, args.repo):
                return (0 if record["state"] == "draft_created" else 2), public(record)
            published_remote_head = record.get("published_remote_head")
            cleanup_worktrees(args.repo, root, fingerprint)
            record = _initial_record(proposal, fingerprint, args.mode)
            if _valid_sha(published_remote_head):
                record["published_remote_head"] = published_remote_head
            atomic_write(path, record)
        record["mode"] = args.mode
        if record["state"] != "eligible":
            stale = _stale_reason(record, args.repo)
            if stale and not (
                record.get("state") == "reviewed"
                and (
                    record.get("pending_rollback")
                    or record.get("published_remote_head")
                )
            ):
                terminal(record, "stale", stale)
                atomic_write(path, record)
                cleanup_worktrees(args.repo, root, fingerprint)
                return 2, public(record)
        try:
            maybe_stop(record, args.stop_after)
            if record["state"] == "eligible":
                snapshot = _remote_snapshot(args.repo, args.base_ref)
                if snapshot["base_sha"] != snapshot["remote_base_sha"]:
                    terminal(record, "rejected", "base_not_remote_tip")
                    atomic_write(path, record)
                    return 2, public(record)
                dirty = git(
                    args.repo,
                    "status",
                    "--porcelain",
                    "--untracked-files=all",
                    "--",
                    ".",
                    ":(exclude).legion",
                    ":(exclude).legion/**",
                    check=False,
                )
                if dirty.returncode != 0 or dirty.stdout.strip():
                    terminal(record, "rejected", "operator_checkout_dirty")
                    atomic_write(path, record)
                    return 2, public(record)
                transition(
                    record,
                    "leased",
                    **snapshot,
                    lease_id="lease-" + fingerprint[:20],
                    branch="legion-improve/" + fingerprint,
                )
                atomic_write(path, record)
                maybe_stop(record, args.stop_after)
            if record["state"] == "leased":
                ensure_worktree(
                    args.repo, root, fingerprint, record["base_sha"], "candidate"
                )
                transition(record, "prepared")
                atomic_write(path, record)
                maybe_stop(record, args.stop_after)
            if record["state"] == "prepared":
                apply_candidate(record, proposal, root)
                candidate = actual_worktree(root, fingerprint)
                paths, lines, patch = changed_paths(candidate)
                target = proposal["target"]["path"]
                expected_paths = _plugin_policy_paths(candidate, target)
                limit = proposal.get("limits", {}).get("max_changed_lines", 200)
                if paths != expected_paths:
                    terminal(record, "rejected", "path_not_allowlisted")
                elif lines > limit:
                    terminal(record, "rejected", "diff_too_large")
                elif patch == EMPTY_DIFF:
                    terminal(record, "rejected", "candidate_no_change")
                else:
                    transition(
                        record,
                        "candidate_ready",
                        diff_digest=patch,
                        changed_lines=lines,
                    )
                atomic_write(path, record)
                if record["state"] in TERMINAL:
                    cleanup_worktrees(args.repo, root, fingerprint)
                    return 2, public(record)
                maybe_stop(record, args.stop_after)
            if record["state"] == "candidate_ready":
                record["repo_runtime"] = os.path.abspath(args.repo)
                failed = evaluate(record, proposal, root, args.evaluation_repeats)
                record.pop("repo_runtime", None)
                if failed:
                    terminal(record, "rejected", failed)
                    atomic_write(path, record)
                    cleanup_worktrees(args.repo, root, fingerprint)
                    return 2, public(record)
                transition(record, "evaluated")
                atomic_write(path, record)
                baseline = actual_worktree(root, fingerprint, "baseline")
                git(args.repo, "worktree", "remove", "--force", str(baseline), check=False)
                maybe_stop(record, args.stop_after)
            if record["state"] == "evaluated":
                independent_review(record, proposal, root)
                record.pop("reason", None)
                transition(record, "reviewed")
                atomic_write(path, record)
                maybe_stop(record, args.stop_after)
            if record["state"] == "reviewed":
                if args.mode == "dry-run":
                    return (
                        2 if record.get("pending_rollback") else 0,
                        public(record),
                    )
                stale = _stale_reason(record, args.repo)
                if stale and not (
                    record.get("pending_rollback")
                    or record.get("published_remote_head")
                ):
                    terminal(record, "stale", stale)
                    atomic_write(path, record)
                    cleanup_worktrees(args.repo, root, fingerprint)
                    return 2, public(record)
                failed = draft(record, proposal, root, args.repo)
                if failed:
                    if failed == "draft_base_changed":
                        terminal(
                            record,
                            "stale",
                            _stale_reason(record, args.repo) or failed,
                        )
                        atomic_write(path, record)
                        cleanup_worktrees(args.repo, root, fingerprint)
                        return 2, public(record)
                    if failed in DRAFT_RETRYABLE:
                        record["reason"] = failed
                        atomic_write(path, record)
                        return 2, public(record)
                    terminal(record, "failed", failed)
                    atomic_write(path, record)
                    cleanup_worktrees(args.repo, root, fingerprint)
                    return 2, public(record)
                record.pop("reason", None)
                transition(record, "draft_created")
                atomic_write(path, record)
                cleanup_worktrees(args.repo, root, fingerprint)
            return 0, public(record)
        except ImproveError as error:
            if error.reason == "stopped_for_resume_test":
                return 2, public(record)
            if record.get("state") == "evaluated" and error.reason in REVIEW_RETRYABLE:
                record["reason"] = error.reason
                atomic_write(path, record)
                return 2, public(record)
            terminal(record, error.state, error.reason)
            record.pop("repo_runtime", None)
            atomic_write(path, record)
            cleanup_worktrees(args.repo, root, fingerprint)
            return 2, public(record)
        except (OSError, subprocess.CalledProcessError):
            if record.get("pending_rollback"):
                # Keep rollback ownership durable and retryable. Terminalizing
                # here would let the generic reset path forget the created PR.
                record["state"] = "reviewed"
                record["transitions"] = list(STEPS[:6])
                record["reason"] = "draft_pr_rollback_failed"
                record.pop("repo_runtime", None)
                atomic_write(path, record)
                return 2, public(record)
            terminal(record, "failed", "internal_operation_failed")
            record.pop("repo_runtime", None)
            atomic_write(path, record)
            cleanup_worktrees(args.repo, root, fingerprint)
            return 2, public(record)


def inspect(args: argparse.Namespace) -> tuple[int, dict[str, Any]]:
    if not re.fullmatch(r"[0-9a-f]{64}", args.fingerprint):
        return 2, error_payload("inspect", "invalid_fingerprint")
    record = read_json(state_path(Path(args.state_dir).resolve(), args.fingerprint))
    if not record:
        return 2, error_payload("inspect", "unknown_fingerprint")
    proposal_identity = {"id": record.get("proposal_id")}
    if not _valid_durable_record(record, proposal_identity, args.fingerprint):
        return 2, error_payload("inspect", "state_corrupt")
    return 0, public(record)


def _bounded_queue_paths(queue_dir: Path, limit: int = 1000) -> list[Path]:
    """Read at most ``limit`` regular queue entries, ignoring symlinks."""
    entries: list[Path] = []
    try:
        with os.scandir(queue_dir) as iterator:
            for entry in iterator:
                if len(entries) >= limit:
                    break
                if (
                    entry.name.endswith(".json")
                    and entry.is_file(follow_symlinks=False)
                ):
                    entries.append(Path(entry.path))
    except OSError:
        return []
    return sorted(entries)


def _quarantine_queue_entry(proposal_path: Path) -> bool:
    """Move one invalid entry out of the active queue without discarding it."""
    quarantine = proposal_path.parent / "quarantine"
    try:
        if quarantine.is_symlink() or (
            quarantine.exists() and not quarantine.is_dir()
        ):
            return False
        quarantine.mkdir(mode=0o700, parents=True, exist_ok=True)
        if (
            quarantine.is_symlink()
            or quarantine.resolve().parent != proposal_path.parent.resolve()
        ):
            return False
        os.chmod(quarantine, 0o700)
        destination = quarantine / f"{proposal_path.name}.invalid"
        for suffix in range(1000):
            candidate = destination if suffix == 0 else Path(f"{destination}.{suffix}")
            if not candidate.exists() and not candidate.is_symlink():
                os.replace(proposal_path, candidate)
                break
        else:
            return False
        return True
    except OSError:
        return False


def _read_proposal(proposal_path: Path) -> dict[str, Any] | None:
    try:
        if proposal_path.stat().st_size > MAX_PROPOSAL_BYTES:
            return None
        value = json.loads(proposal_path.read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return None
    return value if isinstance(value, dict) else None


def process_queue(args: argparse.Namespace) -> tuple[int, dict[str, Any]]:
    if args.mode == "off":
        return 0, {
            "schema": QUEUE_SCHEMA,
            "mode": "off",
            "attempted": 0,
            "failed": 0,
            "skipped_completed": 0,
            "invalid_entries": 0,
            "quarantined": 0,
            "results": [],
        }
    resolved = legion_state.resolve_state(args.repo)
    queue_dir = Path(
        args.queue_dir
        or os.path.join(resolved["state_root"], "self-learn", "improvement-queue")
    ).resolve()
    state_dir = Path(
        args.state_dir or os.path.join(resolved["state_root"], "improve")
    ).resolve()
    results: list[dict[str, Any]] = []
    attempted = 0
    productive = 0
    drafts_created = 0
    failures = 0
    skipped_completed = 0
    invalid_entries = 0
    quarantined = 0
    # Headroom to step past a few stuck entries, proportionate to the bound
    # the operator actually asked for. A flat floor here would silently let
    # `--max 1` run ten full evaluate+review pipelines and overrun the cron
    # window it was set to fit.
    max_attempts = min(50, int(args.max) + 3)
    for proposal_path in _bounded_queue_paths(queue_dir):
        proposal = _read_proposal(proposal_path)
        if validate(proposal):
            invalid_entries += 1
            quarantined += int(_quarantine_queue_entry(proposal_path))
            continue
        assert isinstance(proposal, dict)
        fingerprint = proposal_fingerprint(proposal)
        existing = read_json(state_path(state_dir, fingerprint))
        valid_existing = bool(
            existing and _valid_durable_record(existing, proposal, fingerprint)
        )
        if (
            valid_existing
            and (
                (
                    existing.get("state") in TERMINAL
                    and not _retryable_terminal(existing, proposal, args.repo)
                )
                or (args.mode == "dry-run" and existing.get("state") == "reviewed")
            )
        ):
            skipped_completed += 1
            proposal_path.unlink(missing_ok=True)
            continue
        # "At most --max draft pull requests per refresh" is an invariant of
        # this engine, not a side effect of how many entries happen to be
        # attempted. Count publications, and stop creating once the cap is hit.
        if drafts_created >= args.max:
            continue
        # --max bounds the productive work one refresh performs. A fingerprint
        # that fails every run sorts first every run, and counting its failures
        # against that budget let one permanently stuck entry starve every
        # later proposal indefinitely. Failed attempts therefore do not consume
        # the budget, and a separate attempt ceiling still bounds total work.
        if productive >= args.max:
            continue
        if attempted >= max_attempts:
            continue
        attempted += 1
        run_args = argparse.Namespace(
            repo=args.repo,
            proposal=str(proposal_path),
            state_dir=str(state_dir),
            mode=args.mode,
            evaluation_repeats=args.evaluation_repeats,
            stop_after=None,
            base_ref=args.base_ref,
        )
        code, payload = execute(run_args)
        failures += int(code != 0)
        productive += int(code == 0)
        if payload.get("state") == "draft_created":
            drafts_created += 1
        if code == 0 and args.mode == "dry-run" and payload.get("state") == "reviewed":
            proposal_path.unlink(missing_ok=True)
        if len(results) < 100:
            results.append(
                {
                    "fingerprint": fingerprint,
                    "state": payload.get("state", "failed"),
                    "status": "processed" if code == 0 else "failed",
                }
            )
    payload = {
        "schema": QUEUE_SCHEMA,
        "mode": args.mode,
        "attempted": attempted,
        "drafts_created": drafts_created,
        "failed": failures,
        "skipped_completed": skipped_completed,
        "invalid_entries": invalid_entries,
        "quarantined": quarantined,
        "results": results,
    }
    return (1 if failures or invalid_entries else 0), payload


def parser() -> argparse.ArgumentParser:
    result = argparse.ArgumentParser(
        prog="legion-improve",
        description=(
            "Review-only typed proposal engine.\n"
            "States: eligible -> leased -> prepared -> candidate_ready -> evaluated "
            "-> reviewed -> draft_created.\n"
            "Modes: off, dry-run, draft."
        ),
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    sub = result.add_subparsers(dest="command")
    run = sub.add_parser("run", help="process one typed proposal")
    run.add_argument("--repo", required=True)
    run.add_argument("--proposal", required=True)
    run.add_argument("--state-dir", required=True)
    run.add_argument(
        "--base-ref",
        default="",
        help="freeze this origin branch instead of the operator checkout upstream",
    )
    run.add_argument("--mode", choices=("off", "dry-run", "draft"), default="off")
    run.add_argument("--evaluation-repeats", type=int, default=2)
    run.add_argument("--stop-after", choices=STEPS, help=argparse.SUPPRESS)
    run.add_argument("--json", action="store_true")
    inspect_cmd = sub.add_parser("inspect", help="read a redacted durable run record")
    inspect_cmd.add_argument("--state-dir", required=True)
    inspect_cmd.add_argument("--fingerprint", required=True)
    inspect_cmd.add_argument("--json", action="store_true")
    queue = sub.add_parser(
        "queue", help="process the bounded typed proposal queue from self-learning"
    )
    queue.add_argument("--repo", required=True)
    queue.add_argument("--queue-dir", default="")
    queue.add_argument("--state-dir", default="")
    queue.add_argument("--base-ref", default="main")
    queue.add_argument("--mode", choices=("off", "dry-run", "draft"), default="off")
    queue.add_argument("--max", type=int, default=1)
    queue.add_argument("--evaluation-repeats", type=int, default=2)
    queue.add_argument("--json", action="store_true")
    return result


def main(argv: list[str] | None = None) -> int:
    args = parser().parse_args(argv)
    if args.command == "run":
        if args.evaluation_repeats < 2 or args.evaluation_repeats > 10:
            print(json.dumps(error_payload("run", "evaluation_repeats_out_of_range"), sort_keys=True))
            return 2
        code, payload = execute(args)
    elif args.command == "inspect":
        code, payload = inspect(args)
    elif args.command == "queue":
        if not 1 <= args.max <= 10 or not 2 <= args.evaluation_repeats <= 10:
            print(json.dumps(error_payload("queue", "queue_bounds_out_of_range"), sort_keys=True))
            return 2
        code, payload = process_queue(args)
    else:
        parser().print_help()
        return 2
    print(json.dumps(payload, sort_keys=True, separators=(",", ":")))
    return code


if __name__ == "__main__":
    raise SystemExit(main())
