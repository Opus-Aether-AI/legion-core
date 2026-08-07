#!/usr/bin/env python3
"""Typed, deterministic learning-context compilation primitives.

This module is deliberately dependency-free so every Legion harness can use the
same safe boundary.  It accepts maintainer-authored hints, but emits only the
small set of fields an executor is allowed to see; evidence, transcript, and
excerpt fields never cross that boundary.
"""

from __future__ import annotations

import json
import os
import re
import tempfile
from datetime import datetime, timezone
from typing import Any


HINT_SCHEMA = "legion.learning-hint.v1"
CONTEXT_SCHEMA = "legion.learning-context.v1"
USAGE_SCHEMA = "legion.learning-usage.v1"
EVIDENCE_SCHEMA = "legion.learning-evidence.v1"
STATE_SCHEMA = "legion.learning-state.v1"
ACTIVE_STATUS = "active"
_SCOPE_RANK = {"exact": 0, "selector": 1, "global": 2}
MAX_HINT_DOCUMENT_BYTES = 1_048_576
MAX_HINTS = 100
MAX_TOKENS = 10_000
MAX_EXCLUDED_HINTS = 200
MAX_IDENTIFIER_CHARS = 160
MAX_BOUNDARY_CHARS = 256
MAX_SELECTOR_VALUES = 20
MAX_EVIDENCE_FILE_BYTES = 8_388_608
MAX_EVIDENCE_LINE_BYTES = 65_536
MAX_EVIDENCE_RECORDS = 10_000


def text(value: Any) -> str:
    return value.strip() if isinstance(value, str) else ""


def values(value: Any) -> list[Any]:
    return value if isinstance(value, list) else []


def mapping(value: Any) -> dict[str, Any]:
    return value if isinstance(value, dict) else {}


def token_count(value: str) -> int:
    """A stable, tokenizer-independent conservative budget estimate."""
    # One UTF-8 byte per token is intentionally pessimistic. Unlike a bytes/4
    # average, it remains an upper safety budget for punctuation-heavy text,
    # high-entropy identifiers, and multi-codepoint emoji sequences without
    # coupling this shared boundary to one provider tokenizer.
    return len(value.encode("utf-8"))


def read_json(path: str) -> Any:
    try:
        with open(path, encoding="utf-8") as handle:
            return json.load(handle)
    except (OSError, TypeError, ValueError):
        return None


def read_bounded_json(path: str, max_bytes: int) -> Any:
    """Read one small JSON document without materializing oversized input."""
    try:
        if os.stat(path).st_size > max_bytes:
            return None
        with open(path, encoding="utf-8") as handle:
            return json.load(handle)
    except (OSError, TypeError, ValueError):
        return None


def atomic_write_json(path: str, payload: Any) -> None:
    """Durably replace a JSON state file without exposing partial JSON."""
    directory = os.path.dirname(os.path.abspath(path))
    os.makedirs(directory, exist_ok=True)
    descriptor, temporary = tempfile.mkstemp(prefix=".legion-state-", suffix=".tmp", dir=directory)
    try:
        with os.fdopen(descriptor, "w", encoding="utf-8") as handle:
            json.dump(payload, handle, indent=2, sort_keys=True)
            handle.write("\n")
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(temporary, path)
        try:
            directory_fd = os.open(directory, os.O_RDONLY)
        except OSError:
            directory_fd = -1
        if directory_fd >= 0:
            try:
                os.fsync(directory_fd)
            finally:
                os.close(directory_fd)
    except BaseException:
        try:
            os.unlink(temporary)
        except OSError:
            pass
        raise


def _expired(hint: dict[str, Any], now: datetime) -> bool:
    expires_at = text(hint.get("expires_at"))
    if not expires_at:
        return False
    try:
        parsed = datetime.fromisoformat(expires_at.replace("Z", "+00:00"))
    except ValueError:
        # An invalid lifecycle value must not make a hint permanently active.
        return True
    if parsed.tzinfo is None:
        parsed = parsed.replace(tzinfo=timezone.utc)
    return parsed <= now


def _bounded_text(value: Any, limit: int) -> str:
    value = text(value)
    return value if 0 < len(value) <= limit else ""


def _valid_hint_id(value: Any) -> bool:
    value = text(value)
    return bool(
        value
        and len(value) <= MAX_IDENTIFIER_CHARS
        and re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._:-]*", value)
    )


def _selector_values(value: Any) -> list[str] | None:
    raw = value if isinstance(value, list) else [value]
    if not raw or len(raw) > MAX_SELECTOR_VALUES:
        return None
    result = [_bounded_text(item, MAX_BOUNDARY_CHARS) for item in raw]
    return result if all(result) else None


def _matches_selector(selector: dict[str, Any], request: dict[str, str]) -> bool:
    if not selector or set(selector) - {"repository_identity", "entity", "stage"}:
        return False
    for key, expected in selector.items():
        actual = request.get(key, "")
        expected_values = _selector_values(expected)
        if not actual or expected_values is None or actual not in expected_values:
            return False
    return True


def _match_reason(hint: dict[str, Any], request: dict[str, str], now: datetime) -> str:
    """Return a selection or exclusion reason without returning hint content."""
    if hint.get("schema") not in {None, "", HINT_SCHEMA}:
        return "invalid"
    if not _valid_hint_id(hint.get("id")):
        return "invalid"
    status = text(hint.get("status")).lower()
    if status == "retired":
        return "retired"
    if status == "superseded" or text(hint.get("superseded_by")):
        return "superseded"
    if status != ACTIVE_STATUS:
        return "inactive"
    if _expired(hint, now):
        return "expired"
    if hint.get("trusted") is not True:
        return "untrusted"
    if not text(hint.get("guidance")):
        return "invalid"
    scope = text(hint.get("scope")).lower()
    if scope == "global":
        return "global"
    if scope == "exact":
        entity = text(hint.get("entity"))
        stage = text(hint.get("stage"))
        repository_identity = text(hint.get("repository_identity"))
        if entity and entity != request["entity"]:
            return "exact_mismatch"
        if stage and stage != request["stage"]:
            return "exact_mismatch"
        if repository_identity and repository_identity != request["repository_identity"]:
            return "exact_mismatch"
        return "exact" if entity or stage or repository_identity else "invalid"
    if scope == "selector":
        return "selector" if _matches_selector(mapping(hint.get("selector")), request) else "selector_mismatch"
    return "invalid"


def load_hints(directories: list[str]) -> list[dict[str, Any]]:
    """Read the public hints collection from project then global storage.

    Duplicate IDs are resolved predictably: project storage has precedence over
    global storage, and later duplicate entries in one file are ignored.
    """
    by_id: dict[str, dict[str, Any]] = {}
    for directory in directories:
        document = read_bounded_json(
            os.path.join(directory, "hints.json"), MAX_HINT_DOCUMENT_BYTES
        )
        for hint in values(mapping(document).get("hints")):
            if len(by_id) >= MAX_HINTS + MAX_EXCLUDED_HINTS:
                break
            if not isinstance(hint, dict):
                continue
            hint_id = text(hint.get("id"))
            if _valid_hint_id(hint_id) and hint_id not in by_id:
                by_id[hint_id] = hint
    return [by_id[hint_id] for hint_id in sorted(by_id)]


def _safe_selected_hint(hint: dict[str, Any], reason: str, tokens: int) -> dict[str, Any]:
    """Serialize only executor-safe, maintainer-authored guidance fields."""
    result = {
        "id": text(hint.get("id")),
        "scope": text(hint.get("scope")).lower(),
        "guidance": text(hint.get("guidance")),
        "selection_reason": reason,
        "token_count": tokens,
    }
    for key in ("entity", "stage"):
        value = _bounded_text(hint.get(key), MAX_BOUNDARY_CHARS)
        if value:
            result[key] = value
    return result


def _safe_excluded_hint(hint: dict[str, Any], reason: str) -> dict[str, str]:
    hint_id = text(hint.get("id"))
    return {
        "id": hint_id if _valid_hint_id(hint_id) else "invalid",
        "exclusion_reason": reason,
    }


def compile_context(
    *,
    repository_identity: str,
    entity: str,
    stage: str,
    hint_directories: list[str],
    max_hints: int = 20,
    max_tokens: int = 1200,
    now: datetime | None = None,
) -> dict[str, Any]:
    """Compile the single typed context document delivered to an executor."""
    max_hints = min(MAX_HINTS, max(0, int(max_hints)))
    max_tokens = min(MAX_TOKENS, max(0, int(max_tokens)))
    request = {
        "repository_identity": repository_identity,
        "entity": entity,
        "stage": stage,
    }
    now = now or datetime.now(timezone.utc)
    candidates: list[tuple[int, str, dict[str, Any], str]] = []
    excluded: list[dict[str, str]] = []
    for hint in load_hints(hint_directories):
        reason = _match_reason(hint, request, now)
        if reason in _SCOPE_RANK:
            candidates.append((_SCOPE_RANK[reason], text(hint.get("id")), hint, reason))
        else:
            excluded.append(_safe_excluded_hint(hint, reason))

    selected: list[dict[str, Any]] = []
    used_tokens = 0
    count_limit_reported = False
    for _rank, _hint_id, hint, reason in sorted(candidates, key=lambda item: (item[0], item[1])):
        guidance_tokens = token_count(text(hint.get("guidance")))
        # When both limits are exhausted, report each deterministically.  This
        # makes a compiled document explain all active constraints instead of
        # hiding the count cap behind the token cap.
        over_count = len(selected) >= max_hints
        over_tokens = used_tokens + guidance_tokens > max_tokens
        if over_count and not count_limit_reported:
            excluded.append(_safe_excluded_hint(hint, "hint_limit"))
            count_limit_reported = True
        elif over_tokens:
            excluded.append(_safe_excluded_hint(hint, "token_limit"))
        elif over_count:
            excluded.append(_safe_excluded_hint(hint, "hint_limit"))
        else:
            selected.append(_safe_selected_hint(hint, reason, guidance_tokens))
            used_tokens += guidance_tokens

    excluded.sort(key=lambda item: (item["id"], item["exclusion_reason"]))
    excluded = excluded[:MAX_EXCLUDED_HINTS]
    usage = {
        "schema": USAGE_SCHEMA,
        "hint_count": len(selected),
        "token_count": used_tokens,
    }
    return {
        "schema": CONTEXT_SCHEMA,
        "repository_identity": repository_identity,
        "entity": entity,
        "stage": stage,
        "limits": {"max_hints": max_hints, "max_tokens": max_tokens},
        "usage": usage,
        "selected_hints": selected,
        "excluded_hints": excluded,
    }


def safe_legacy_identity(legacy_identity: str, repository_identity: str) -> bool:
    """Accept a legacy path identity only when its basename anchors the repo."""
    legacy_identity = text(legacy_identity)
    if not legacy_identity or not os.path.isabs(legacy_identity):
        return False
    legacy_name = os.path.basename(os.path.normpath(legacy_identity)).lower()
    repository_name = repository_identity.rstrip("/").rsplit("/", 1)[-1].lower()
    return bool(legacy_name and repository_name and legacy_name == repository_name)


def read_evidence(
    path: str, repository_identity: str
) -> tuple[list[dict[str, str]], int, int, int]:
    """Replay only canonical, same-repository evidence and deduplicate by ID."""
    replayed = 0
    limited = 0
    by_id: dict[str, dict[str, str]] = {}
    try:
        handle = open(path, "rb")
    except OSError:
        return [], 0, 0, 0
    total_bytes = 0
    records_seen = 0
    with handle:
        while total_bytes < MAX_EVIDENCE_FILE_BYTES and records_seen < MAX_EVIDENCE_RECORDS:
            line = handle.readline(MAX_EVIDENCE_LINE_BYTES + 1)
            if not line:
                break
            total_bytes += len(line)
            records_seen += 1
            if len(line) > MAX_EVIDENCE_LINE_BYTES and not line.endswith(b"\n"):
                limited += 1
                while line and not line.endswith(b"\n"):
                    line = handle.readline(MAX_EVIDENCE_LINE_BYTES + 1)
                    total_bytes += len(line)
                    if total_bytes >= MAX_EVIDENCE_FILE_BYTES:
                        break
                continue
            try:
                evidence = json.loads(line.decode("utf-8"))
            except (TypeError, UnicodeDecodeError, ValueError):
                continue
            if not isinstance(evidence, dict) or evidence.get("schema") != EVIDENCE_SCHEMA:
                continue
            if text(evidence.get("repository_identity")) != repository_identity:
                continue
            evidence_id = _bounded_text(evidence.get("id"), MAX_IDENTIFIER_CHARS)
            entity = _bounded_text(evidence.get("entity"), MAX_BOUNDARY_CHARS)
            outcome = _bounded_text(evidence.get("outcome"), MAX_BOUNDARY_CHARS)
            evidence_digest = _bounded_text(evidence.get("digest"), MAX_IDENTIFIER_CHARS)
            if not evidence_id:
                continue
            replayed += 1
            # Do not retain arbitrary evidence payload fields; in particular no
            # transcripts, excerpts, prompts, or command output cross into state.
            by_id.setdefault(
                evidence_id,
                {
                    "id": evidence_id,
                    "entity": entity,
                    "outcome": outcome,
                    "digest": evidence_digest,
                },
            )
        if handle.read(1):
            limited += 1
    records = [by_id[evidence_id] for evidence_id in sorted(by_id)]
    return records, replayed, replayed - len(records), limited


def reconcile_state(
    *,
    repository_identity: str,
    state_path: str,
    legacy_state_path: str = "",
    evidence_path: str = "",
) -> dict[str, Any]:
    """Safely migrate one compatible legacy state and replay evidence once."""
    current = read_json(state_path)
    current_state = mapping(current)
    if current_state.get("schema") == STATE_SCHEMA and text(
        current_state.get("repository_identity")
    ) == repository_identity:
        state = current_state
    else:
        # Never merge a state file merely because it happens to be at the same
        # path: a reused state root must not leak another repository's learning.
        state = {}
    state = dict(state)
    state["schema"] = STATE_SCHEMA
    state["repository_identity"] = repository_identity
    if not isinstance(state.get("entities"), dict):
        state["entities"] = {}
    if not isinstance(state.get("evidence"), list):
        state["evidence"] = []
    reconciled: list[str] = []
    legacy = mapping(read_json(legacy_state_path)) if legacy_state_path else {}
    legacy_identity = text(legacy.get("repository") or legacy.get("repository_identity"))
    if legacy and safe_legacy_identity(legacy_identity, repository_identity):
        reconciled.append(legacy_identity)
        for entity, entry in sorted(mapping(legacy.get("entities")).items()):
            if not isinstance(entry, dict) or not text(entity):
                continue
            target = mapping(state["entities"].setdefault(entity, {}))
            ids = sorted({text(item) for item in values(target.get("evidence_ids")) + values(entry.get("evidence_ids")) if text(item)})
            if ids:
                target["evidence_ids"] = ids
            state["entities"][entity] = target

    records, replayed, deduplicated, limited = (
        read_evidence(evidence_path, repository_identity)
        if evidence_path
        else ([], 0, 0, 0)
    )
    safe_existing = [
        {key: text(item.get(key)) for key in ("id", "entity", "outcome", "digest")}
        for item in values(state.get("evidence"))[:MAX_EVIDENCE_RECORDS]
        if isinstance(item, dict)
        and _bounded_text(item.get("id"), MAX_IDENTIFIER_CHARS)
    ]
    record_ids = {item["id"] for item in safe_existing}
    for record in records:
        if (
            len(safe_existing) < MAX_EVIDENCE_RECORDS
            and record["id"] not in record_ids
        ):
            safe_existing.append(record)
            record_ids.add(record["id"])
        if record["entity"]:
            entity = mapping(state["entities"].setdefault(record["entity"], {}))
            entity["evidence_ids"] = sorted(
                {
                    bounded
                    for item in values(entity.get("evidence_ids")) + [record["id"]]
                    if (bounded := _bounded_text(item, MAX_IDENTIFIER_CHARS))
                }
            )[:MAX_EVIDENCE_RECORDS]
            state["entities"][record["entity"]] = entity
    state["evidence"] = sorted(safe_existing, key=lambda item: item["id"])
    atomic_write_json(state_path, state)
    return {
        "schema": STATE_SCHEMA,
        "repository_identity": repository_identity,
        "reconciled_legacy_identities": reconciled,
        "evidence_ids": [record["id"] for record in records],
        "evidence_replayed": replayed,
        "evidence_deduplicated": deduplicated,
        "evidence_limited": limited,
        "state_path": state_path,
    }
