#!/usr/bin/env python3
"""Evidence-linked, local-first learning for Legion.

The v2 learning lane turns bounded agent-session events into explainable
sessions, episodes, decisions, outcome links, behavior scores, and reusable
laws. Raw transcript content is streamed, redacted, and discarded. The daily
lane is report/proposal only; source candidates belong to the separate,
review-only ``legion-improve`` state machine.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import subprocess
import sys
import tempfile
from collections import defaultdict
from collections.abc import Iterable
from datetime import datetime, timedelta, timezone
from functools import lru_cache
from pathlib import Path
from typing import Any

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import legion_state

EVENT_SCHEMA = "legion.session-event.v1"
SESSION_SCHEMA = "legion.session-summary.v1"
EPISODE_SCHEMA = "legion.episode.v1"
DECISION_SCHEMA = "legion.decision.v1"
OUTCOME_LINK_SCHEMA = "legion.outcome-link.v1"
LAW_SCHEMA = "legion.learning-law.v1"
REPORT_SCHEMA = "legion.learning.report.v2"
MAX_EXCERPT_CHARS = 700
DEFAULT_MAX_SESSION_FILES = 100
DEFAULT_MAX_SESSION_TOTAL_MB = 64.0
DEFAULT_MAX_EVENTS = 20_000
DEFAULT_MAX_REPO_CANDIDATE_FILES = 1_000
DEFAULT_MAX_REPO_CANDIDATE_TOTAL_MB = 256.0

BEHAVIOR_AXES = (
    "execution_leverage",
    "steering",
    "engineering_quality",
    "product_thinking",
    "planning",
)

CODE_QUALITY_DIMENSIONS = (
    "commit_discipline",
    "test_quality",
    "code_quality",
    "error_handling",
    "security_signals",
    "architecture",
    "documentation",
    "agent_config_quality",
    "infrastructure",
    "dependency_management",
    "git_workflow",
    "code_evolution",
    "performance_awareness",
    "production_readiness",
)

# Order is deliberate: specific corrections win over broad audit/verification
# language. These laws include the recurring Paxel report patterns plus the
# webapp-specific corrections requested for this implementation.
LAW_PATTERNS: tuple[tuple[str, tuple[str, ...]], ...] = (
    (
        "source-of-truth",
        (
            r"\bwrong source\b",
            r"\bsource of truth\b",
            r"\buse\s+\w+\s*,?\s+not\s+\w+",
            r"\bnot linear\b",
            r"\bgo for plane\b",
        ),
    ),
    (
        "harness-identity",
        (
            r"\byou are (?:codex|claude|cursor)\b",
            r"\bnot (?:codex|claude|cursor)\b",
            r"\bright (?:client|harness|agent)\b",
            r"\bclient mismatch\b",
        ),
    ),
    (
        "test-real-workflow",
        (
            r"\bactually test\b.*\b(?:e2e|workflow|hermes|production|live)\b",
            r"\btest (?:it|this) with\b",
            r"\breal (?:workflow|product|integration)\b",
            r"\bbefore updating (?:the )?(?:page|docs|documentation)\b",
        ),
    ),
    (
        "stale-automation",
        (
            r"\bstale\b.*\b(?:run|check|data|state|job)\b",
            r"\bsuperseded\b.*\b(?:run|check|pr|job)\b",
            r"\bkeeps? chasing\b",
            r"\bskip green latest checks\b",
        ),
    ),
    (
        "visible-acceptance",
        (
            r"\b(?:ui|panel|page|layout|design)\b.*\b(?:trash|wrong|broken|missing|ugly)\b",
            r"\binspect the (?:live )?ui\b",
            r"\bvisual acceptance\b",
            r"\bthis is not there anymore\b",
        ),
    ),
    (
        "centralize-configuration",
        (
            r"\bcentrali[sz]e\b.*\bconfig",
            r"\bone configuration file\b",
            r"\bscattered hardcoded\b",
            r"\bsingle source\b.*\bconfig",
        ),
    ),
    (
        "audit-completeness",
        (
            r"\baudit all\b",
            r"\bwhole (?:repo|surface|flow)\b",
            r"\ball references\b",
            r"\bcomplete(?:ness| sweep)?\b",
            r"\badversarial (?:review|audit)\b",
        ),
    ),
    (
        "full-stop-and-investigate",
        (
            r"\bstop and investigate\b",
            r"\bfind (?:the )?root cause\b",
            r"\bwhy (?:is|did|does|the hell)\b",
            r"\bdon't keep\b.*\b(?:retry|continue|patch)\b",
        ),
    ),
    (
        "enforce-safety-rails",
        (
            r"\bfail[- ]closed\b",
            r"\bsafety (?:rail|gate|invariant)\b",
            r"\bmanual (?:arm|approval)\b",
            r"\bno[- ]go\b",
            r"\bdry[- ]run\b.*\bbefore\b",
        ),
    ),
    (
        "scope-the-version-boundary",
        (
            r"\bonly (?:change|touch|modify)\b",
            r"\bexact version\b",
            r"\bversion boundary\b",
            r"\bavoid unrelated\b",
            r"\bdo not (?:touch|change|modify)\b",
        ),
    ),
    (
        "demand-production-parity",
        (
            r"\bproduction parity\b",
            r"\bworks? (?:in|on) production\b",
            r"\bverify (?:production|live)\b",
            r"\blive outcome\b",
            r"\bparity with\b",
        ),
    ),
    (
        "catch-the-state-bug",
        (
            r"\bstale state\b",
            r"\bstate bug\b",
            r"\bduplicate\b.*\b(?:record|event|run|order)\b",
            r"\bpaused.*resumed\b",
            r"\bwrong state\b",
        ),
    ),
    (
        "workflow-from-user-backwards",
        (
            r"\buser workflow\b",
            r"\bfrom the user\b",
            r"\bactual positions\b",
            r"\bdaily stats\b",
            r"\bwhat the user sees\b",
        ),
    ),
    (
        "demand-before-after-proof",
        (
            r"\bbefore[- /]after\b",
            r"\bprove (?:it|the|that)\b",
            r"\bshow (?:the )?(?:diff|evidence|result)\b",
            r"\bexact validation results\b",
        ),
    ),
    (
        "codify-the-lesson",
        (
            r"\blearn from this\b",
            r"\bcodify\b.*\blesson\b",
            r"\bturn .* into (?:a )?guardrail\b",
            r"\bshould have learned\b",
        ),
    ),
    (
        "correct-the-tool-choice",
        (
            r"\bwrong tool\b",
            r"\buse .* instead of\b",
            r"\bnot playwright mcp\b",
            r"\bredirect.*existing tool\b",
        ),
    ),
)

LAW_GUIDANCE: dict[str, tuple[str, str]] = {
    "source-of-truth": (
        "Confirm the authoritative system before changing integrations, data, or workflow state.",
        "Name the selected source and validate one representative read/write against it.",
    ),
    "harness-identity": (
        "Detect the active agent harness and use its native configuration, tools, and session format.",
        "Run a harness-native smoke check and report the detected harness.",
    ),
    "test-real-workflow": (
        "Validate the real user workflow before changing the documentation or interface that describes it.",
        "Run a representative end-to-end workflow and retain its result as evidence.",
    ),
    "stale-automation": (
        "Stop automation from acting on stale, superseded, or already-successful state.",
        "Replay stale and superseded fixtures and prove that only the current failing state is actionable.",
    ),
    "visible-acceptance": (
        "Treat the rendered interface as acceptance evidence, not just a successful build.",
        "Inspect the affected live view at its target viewport and capture visual acceptance evidence.",
    ),
    "centralize-configuration": (
        "Keep shared policy and defaults in one discoverable configuration source.",
        "Search for duplicate values and prove all supported consumers resolve the centralized setting.",
    ),
    "audit-completeness": (
        "Search the entire bounded surface and account for every relevant reference before declaring completion.",
        "Report the search scope, reference count, and any explicit exclusions.",
    ),
    "full-stop-and-investigate": (
        "Pause repeated patching when evidence points to an unexplained root cause.",
        "State the root cause and reproduce it before validating the correction.",
    ),
    "enforce-safety-rails": (
        "Make high-impact actions fail closed behind explicit safety invariants.",
        "Exercise the no-go and dry-run paths before the permitted path.",
    ),
    "scope-the-version-boundary": (
        "Constrain changes to the requested version and preserve unrelated user work.",
        "Review the final diff for out-of-scope paths and behavior.",
    ),
    "demand-production-parity": (
        "Validate the production or live execution path when local success is insufficient.",
        "Compare local and production-facing outcomes for the same representative input.",
    ),
    "catch-the-state-bug": (
        "Model state transitions explicitly and test duplicate, stale, pause, and resume paths.",
        "Replay transition and idempotency fixtures around the corrected state boundary.",
    ),
    "workflow-from-user-backwards": (
        "Design and validate from the user's observable workflow back to internal components.",
        "Demonstrate the complete user-visible outcome with representative data.",
    ),
    "demand-before-after-proof": (
        "Retain comparable evidence from before and after the change.",
        "Report the same measurement or workflow result on both revisions.",
    ),
    "codify-the-lesson": (
        "Turn a repeated correction into a durable test, check, or scoped guardrail.",
        "Reproduce the old failure with the new guardrail and show that it now stops or redirects it.",
    ),
    "correct-the-tool-choice": (
        "Use the tool that owns the target workflow and supports the required evidence.",
        "Run a minimal native-tool smoke check before the full workflow.",
    ),
}

_EMAIL_RE = re.compile(r"\b[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}\b", re.IGNORECASE)
_BEARER_RE = re.compile(r"\bBearer\s+[A-Za-z0-9._~+/=-]{8,}", re.IGNORECASE)
_CREDENTIAL_RES = (
    re.compile(r"\bgh[oprsu]_[A-Za-z0-9]{20,}\b"),
    re.compile(r"\bsk-(?:proj-)?[A-Za-z0-9_-]{16,}\b"),
    re.compile(r"\bxox[a-z]-[A-Za-z0-9-]{10,}\b", re.IGNORECASE),
    re.compile(r"\b(?:AKIA|ASIA)[A-Z0-9]{16}\b"),
    re.compile(r"\beyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{8,}\b"),
    re.compile(r"(?i)\b(?:api[_-]?key|token|secret|password)\s*[:=]\s*['\"]?[A-Za-z0-9._~+/=-]{8,}"),
)
_PRIVATE_KEY_RE = re.compile(
    r"-----BEGIN [^-\r\n]*PRIVATE KEY-----.*?"
    r"(?:-----END [^-\r\n]*PRIVATE KEY-----|$)",
    re.IGNORECASE | re.DOTALL,
)
_FILE_URI_RE = re.compile(
    r"\bfile://[^\s'\"`<>{}\[\](),;]+",
    re.IGNORECASE,
)
_PATH_RE = re.compile(
    r"(?:(?<![A-Za-z0-9:/])/(?!/)(?:[^/\s'\"`<>{}\[\](),;:]+/)+"
    r"[^/\s'\"`<>{}\[\](),;:]+"
    r"|(?<![A-Za-z0-9])[A-Za-z]:\\[^\s'\"`<>{}\[\](),;:]+)"
)
_CONNECTION_RE = re.compile(
    r"\b(?:postgres(?:ql)?|redis|mongodb(?:\+srv)?|mysql|mssql|amqp)://[^\s]+",
    re.IGNORECASE,
)

_VERIFIED_RE = re.compile(
    r"\b(?:tests?|checks?|ci|lint|typecheck|build)\b.*\b(?:pass(?:ed|ing)?|green|ok|complete)\b"
    r"|\b(?:verified|validated)\b.*\b(?:production|live|workflow|e2e|result)?\b",
    re.IGNORECASE,
)
_FAILED_RE = re.compile(
    r"\b(?:tests?|checks?|ci|build|deploy|validation)\b.*\b(?:fail(?:ed|ing)?|red|error|broken)\b"
    r"|\b(?:rollback|regression|no[- ]go)\b",
    re.IGNORECASE,
)
_VERIFIED_CUE_RE = re.compile(
    r"\b(?:pass(?:ed|ing)?|green|ok|complete|verified|validated)\b",
    re.IGNORECASE,
)
_FAILED_CUE_RE = re.compile(
    r"\b(?:fail(?:ed|ing)?|red|error|broken|rollback|regression|no[- ]go)\b",
    re.IGNORECASE,
)
_NEGATION_BEFORE_CUE_RE = re.compile(
    r"(?:\b(?:no|not|never|cannot)\b|n['’]t\b)(?:\W+\w+){0,4}\W*$",
    re.IGNORECASE,
)
_NEGATION_BOUNDARY_RE = re.compile(
    r"[.!?;]|\b(?:but|however|later|subsequently|then|afterwards)\b",
    re.IGNORECASE,
)
_NOT_ONLY_RE = re.compile(r"\bnot\s+only\b", re.IGNORECASE)


def _now() -> datetime:
    return datetime.now(timezone.utc)


def _iso_now() -> str:
    return _now().isoformat().replace("+00:00", "Z")


def _stable_id(parts: Iterable[Any]) -> str:
    raw = json.dumps(list(parts), sort_keys=True, ensure_ascii=True, default=str)
    return hashlib.sha256(raw.encode("utf-8")).hexdigest()[:16]


def _short(text: str, limit: int = MAX_EXCERPT_CHARS) -> str:
    collapsed = " ".join((text or "").split())
    return collapsed if len(collapsed) <= limit else collapsed[: limit - 3].rstrip() + "..."


def redact_text(text: str, *, limit: int = MAX_EXCERPT_CHARS) -> str:
    """Return a bounded, fail-closed excerpt safe for durable learning state."""
    value = str(text or "")
    value = _CONNECTION_RE.sub("[credential-url]", value)
    value = _BEARER_RE.sub("Bearer [credential]", value)
    value = _PRIVATE_KEY_RE.sub("[private-key]", value)
    value = _FILE_URI_RE.sub("file://[path]", value)
    for pattern in _CREDENTIAL_RES:
        value = pattern.sub("[credential]", value)
    value = _EMAIL_RE.sub("[email]", value)
    value = _PATH_RE.sub("[path]", value)
    return _short(value, limit)


def redact_payload(value: Any) -> Any:
    """Recursively redact string leaves while preserving JSON structure."""
    if isinstance(value, dict):
        return {str(key): redact_payload(item) for key, item in value.items()}
    if isinstance(value, list):
        return [redact_payload(item) for item in value]
    if isinstance(value, tuple):
        return [redact_payload(item) for item in value]
    if isinstance(value, str):
        return redact_text(value, limit=max(len(value), MAX_EXCERPT_CHARS))
    return value


def _source_for_path(path: Path) -> str:
    lowered = str(path).lower()
    if ".codex" in lowered:
        return "codex"
    if ".claude" in lowered:
        return "claude"
    if ".cursor" in lowered:
        return "cursor"
    if "opencode" in lowered:
        return "opencode"
    if ".gemini" in lowered or "antigravity" in lowered:
        return "gemini"
    return "unknown"


def _project_for_path(path: Path, home: Path | None = None) -> str:
    parts = list(path.parts)
    for marker in ("sessions", "projects"):
        if marker in parts:
            index = parts.index(marker)
            if index + 1 < len(parts) - 1:
                candidate = re.sub(r"[^a-zA-Z0-9._-]+", "-", parts[index + 1]).strip("-")
                if candidate and candidate not in {"2025", "2026"}:
                    return candidate
    if home:
        try:
            rel = path.relative_to(home)
            if len(rel.parts) > 1:
                return rel.parts[-2]
        except ValueError:
            pass
    return path.parent.name or "unknown"


@lru_cache(maxsize=2048)
def _project_for_cwd(cwd: str) -> str:
    path = Path(cwd).expanduser()
    return _durable_repository_identity(str(path))


def _durable_repository_identity(repo: str) -> str:
    identity = legion_state.repository_identity(repo)
    if os.path.isabs(identity):
        opaque_id = legion_state.repository_project_id(repo, identity)
        return f"local:{opaque_id}"
    return identity or Path(repo).expanduser().name or "unknown"


def safe_project_component(value: str) -> str:
    """Return a path-safe project label for report and snapshot filenames."""
    component = re.sub(r"[^a-z0-9._-]+", "-", str(value or "").lower()).strip("-.")
    return component or "project"


def _session_cwd(payload: dict[str, Any]) -> str:
    candidates = [payload]
    body = payload.get("payload")
    if isinstance(body, dict):
        candidates.append(body)
    for candidate in candidates:
        value = candidate.get("cwd") or candidate.get("working_directory")
        if isinstance(value, str) and value.strip():
            return value.strip()
    return ""


def _message_role(payload: dict[str, Any]) -> str:
    message = payload.get("message") if isinstance(payload.get("message"), dict) else {}
    role = message.get("role") if isinstance(message, dict) else None
    if isinstance(role, str):
        return role.lower()
    if isinstance(payload.get("role"), str):
        return str(payload["role"]).lower()
    body = payload.get("payload") if isinstance(payload.get("payload"), dict) else {}
    kind = str(body.get("type") or "").lower()
    if kind in {"user_message", "user"}:
        return "user"
    if kind in {"agent_message", "assistant", "assistant_message"}:
        return "assistant"
    if isinstance(body.get("role"), str):
        return str(body["role"]).lower()
    return "unknown"


def _content_text(value: Any) -> str:
    if isinstance(value, str):
        return value
    if isinstance(value, list):
        parts: list[str] = []
        for item in value:
            if isinstance(item, dict) and item.get("type") in {"text", "input_text", "output_text"}:
                parts.append(str(item.get("text") or ""))
            elif isinstance(item, str):
                parts.append(item)
        return "\n".join(part for part in parts if part)
    if isinstance(value, dict):
        for key in ("message", "content", "text", "summary"):
            text = _content_text(value.get(key))
            if text:
                return text
    return ""


def _message_text(payload: dict[str, Any]) -> str:
    message = payload.get("message") if isinstance(payload.get("message"), dict) else {}
    text = _content_text(message.get("content")) if isinstance(message, dict) else ""
    if text:
        return text
    body = payload.get("payload") if isinstance(payload.get("payload"), dict) else {}
    text = _content_text(body)
    if text:
        return text
    return _content_text(payload)


def _dispatches(payload: dict[str, Any]) -> list[dict[str, Any]]:
    message = payload.get("message") if isinstance(payload.get("message"), dict) else {}
    content = message.get("content") if isinstance(message, dict) else None
    items = list(content) if isinstance(content, list) else []
    body = payload.get("payload") if isinstance(payload.get("payload"), dict) else {}
    if payload.get("type") == "response_item" and body.get("type") == "function_call":
        items.append(body)
    out: list[dict[str, Any]] = []
    for item in items:
        if not isinstance(item, dict) or item.get("type") not in {"tool_use", "function_call"}:
            continue
        name = str(item.get("name") or "")
        if name.lower() not in {"agent", "task", "spawn_agent", "delegate", "legion-delegate"}:
            continue
        tool_input = item.get("input") if isinstance(item.get("input"), dict) else {}
        arguments = item.get("arguments")
        if not tool_input and isinstance(arguments, dict):
            tool_input = arguments
        elif not tool_input and isinstance(arguments, str):
            try:
                parsed_arguments = json.loads(arguments)
            except ValueError:
                parsed_arguments = {}
            if isinstance(parsed_arguments, dict):
                tool_input = parsed_arguments
        prompt = str(
            tool_input.get("prompt")
            or tool_input.get("task")
            or tool_input.get("message")
            or ""
        )
        out.append(
            {
                "name": name or "dispatch",
                "hash": hashlib.sha256(prompt.encode("utf-8")).hexdigest()[:12],
                "background": bool(tool_input.get("run_in_background")),
            }
        )
    return out


def normalize_session_file(path: Path, *, home: Path | None = None) -> list[dict[str, Any]]:
    """Stream one session file into bounded normalized events."""
    path = Path(path)
    source = _source_for_path(path)
    project = _project_for_path(path, home)
    session_id = _stable_id([source, str(path)])
    events: list[dict[str, Any]] = []
    cwd_project = ""
    try:
        handle = path.open(encoding="utf-8", errors="ignore")
    except OSError:
        return []
    with handle:
        for index, line in enumerate(handle):
            try:
                payload = json.loads(line)
            except ValueError:
                continue
            if not isinstance(payload, dict):
                continue
            cwd = _session_cwd(payload)
            if cwd:
                cwd_project = _project_for_cwd(cwd)
            timestamp = str(
                payload.get("timestamp")
                or payload.get("ts")
                or payload.get("created_at")
                or ""
            )
            role = _message_role(payload)
            text = _message_text(payload)
            if text:
                excerpt = redact_text(text)
                if excerpt:
                    events.append(
                        {
                            "schema": EVENT_SCHEMA,
                            "id": _stable_id([session_id, index, role, excerpt]),
                            "session_id": session_id,
                            "source": source,
                            "project": project,
                            "ts": timestamp,
                            "sequence": index,
                            "role": role,
                            "event_type": "message",
                            "excerpt": excerpt,
                        }
                    )
            for offset, dispatch in enumerate(_dispatches(payload)):
                events.append(
                    {
                        "schema": EVENT_SCHEMA,
                        "id": _stable_id([session_id, index, "dispatch", offset, dispatch["hash"]]),
                        "session_id": session_id,
                        "source": source,
                        "project": project,
                        "ts": timestamp,
                        "sequence": index,
                        "role": "assistant",
                        "event_type": "dispatch",
                        "excerpt": f"{dispatch['name']} dispatch",
                        "dispatch_hash": dispatch["hash"],
                        "run_in_background": dispatch["background"],
                    }
                )
    if cwd_project:
        for event in events:
            event["project"] = cwd_project
    return sorted(events, key=lambda item: (int(item.get("sequence") or 0), item["id"]))


def filter_events_for_repo(
    events: list[dict[str, Any]], repo: str
) -> list[dict[str, Any]]:
    """Select events attributed to one repository without transcript search."""
    target = _project_for_cwd(repo)
    return [event for event in events if str(event.get("project") or "") == target]


def classify_decision_law(text: str) -> tuple[str, list[str]]:
    matched: list[str] = []
    for law, patterns in LAW_PATTERNS:
        hits = [pattern for pattern in patterns if re.search(pattern, text or "", re.IGNORECASE | re.DOTALL)]
        if hits:
            return law, hits
    return "unclassified", matched


def _decision_type(text: str, law: str) -> str:
    lower = (text or "").lower()
    if law in {"source-of-truth", "harness-identity", "catch-the-state-bug"}:
        return "technical_catch"
    if law in {"visible-acceptance", "workflow-from-user-backwards"}:
        return "product_insight"
    if re.search(r"\bchoose|selected|go with|use .* not\b", lower):
        return "option_selection"
    return "strategic_redirect"


def _intent(events: list[dict[str, Any]]) -> str:
    text = " ".join(event.get("excerpt", "") for event in events if event.get("role") == "user")
    if re.search(r"\b(?:implement|fix|ship|merge|deploy|release|build|create|change)\b", text, re.IGNORECASE):
        return "shipping"
    if re.search(r"\b(?:review|audit|research|investigate|compare|find|plan|explain)\b", text, re.IGNORECASE):
        return "exploration"
    return "ambiguous"


def _cue_is_negated(excerpt: str, cue_start: int) -> bool:
    prefix = excerpt[:cue_start]
    boundaries = list(_NEGATION_BOUNDARY_RE.finditer(prefix))
    clause = prefix[boundaries[-1].end() :] if boundaries else prefix
    clause = _NOT_ONLY_RE.sub("", clause)
    return bool(_NEGATION_BEFORE_CUE_RE.search(clause))


def _latest_outcome_evidence(
    events: list[dict[str, Any]],
    *,
    min_sequence: int | None = None,
    exclude_event_id: str = "",
) -> tuple[str, dict[str, Any] | None]:
    candidates: list[tuple[int, int, str, dict[str, Any]]] = []
    for event in events:
        sequence = int(event.get("sequence") or 0)
        if min_sequence is not None and sequence < min_sequence:
            continue
        if event.get("id") == exclude_event_id or event.get("role") == "user":
            continue
        excerpt = str(event.get("excerpt") or "")
        for status, pattern, cue_pattern in (
            ("verified", _VERIFIED_RE, _VERIFIED_CUE_RE),
            ("failed", _FAILED_RE, _FAILED_CUE_RE),
        ):
            for match in pattern.finditer(excerpt):
                for cue in cue_pattern.finditer(excerpt, match.start(), match.end()):
                    cue_status = status
                    if _cue_is_negated(excerpt, cue.start()):
                        cue_status = "failed" if status == "verified" else "verified"
                    candidates.append((sequence, cue.end(), cue_status, event))
    selected = max(candidates, default=None, key=lambda item: (item[0], item[1]))
    if not selected:
        return "no_evidence", None
    return selected[2], selected[3]


def _outcome_for(decision: dict[str, Any], session_events: list[dict[str, Any]]) -> dict[str, Any]:
    status, evidence = _latest_outcome_evidence(
        session_events,
        min_sequence=int(decision.get("sequence") or 0),
        exclude_event_id=str(decision.get("event_id") or ""),
    )
    confidence = "high" if evidence else "low"
    return {
        "schema": OUTCOME_LINK_SCHEMA,
        "id": _stable_id([decision["id"], evidence.get("id") if evidence else status]),
        "decision_id": decision["id"],
        "episode_id": decision["episode_id"],
        "status": status,
        "confidence": confidence,
        "evidence_ids": [evidence["id"]] if evidence else [],
        "evidence_excerpt": evidence.get("excerpt", "") if evidence else "",
    }


def _axis_score(
    axis: str,
    *,
    events: list[dict[str, Any]],
    decisions: list[dict[str, Any]],
    links: list[dict[str, Any]],
    sessions: list[dict[str, Any]],
) -> dict[str, Any]:
    verified = sum(link.get("status") == "verified" for link in links)
    failed = sum(link.get("status") == "failed" for link in links)
    dispatches = sum(event.get("event_type") == "dispatch" for event in events)
    shipping = sum(session.get("intent") == "shipping" for session in sessions)
    corrections = len(decisions)
    if axis == "execution_leverage":
        raw = 4.0 + min(3.0, dispatches * 0.5) + min(3.0, verified * 0.35) - failed * 0.4
        evidence_ids = [event["id"] for event in events if event.get("event_type") == "dispatch"][:5]
    elif axis == "steering":
        raw = 4.0 + min(4.0, corrections * 0.35) + min(2.0, verified * 0.2)
        evidence_ids = [decision["id"] for decision in decisions[:5]]
    elif axis == "engineering_quality":
        raw = 4.0 + min(5.0, verified * 0.45) - min(3.0, failed * 0.6)
        evidence_ids = [link["id"] for link in links if link.get("status") != "no_evidence"][:5]
    elif axis == "product_thinking":
        product = sum(
            decision.get("law_key") in {"visible-acceptance", "workflow-from-user-backwards", "source-of-truth"}
            for decision in decisions
        )
        raw = 4.0 + min(6.0, product * 0.7)
        evidence_ids = [
            decision["id"]
            for decision in decisions
            if decision.get("law_key") in {"visible-acceptance", "workflow-from-user-backwards", "source-of-truth"}
        ][:5]
    else:
        planning = sum(
            bool(re.search(r"\b(?:plan|phase|scope|milestone|before|after)\b", event.get("excerpt", ""), re.IGNORECASE))
            for event in events
            if event.get("role") == "user"
        )
        raw = 4.0 + min(4.0, planning * 0.35) + min(2.0, shipping * 0.2)
        evidence_ids = [
            event["id"]
            for event in events
            if event.get("role") == "user"
            and re.search(r"\b(?:plan|phase|scope|milestone|before|after)\b", event.get("excerpt", ""), re.IGNORECASE)
        ][:5]
    evidence_count = len(evidence_ids)
    return {
        "score": round(max(0.0, min(10.0, raw)), 2),
        "confidence": "high" if evidence_count >= 3 else "medium" if evidence_count else "low",
        "evidence_ids": evidence_ids,
        "scorer": "deterministic-v1",
    }


def _repo_files(repo: str, limit: int = 5000) -> list[Path]:
    root = Path(repo)
    if not root.is_dir():
        return []
    ignored = {".git", "node_modules", ".venv", "venv", "dist", "build", ".next"}
    files: list[Path] = []
    for path in root.rglob("*"):
        if any(part in ignored for part in path.parts):
            continue
        if path.is_file():
            files.append(path)
            if len(files) >= limit:
                break
    return files


def _git_count(repo: str, args: list[str]) -> int:
    try:
        proc = subprocess.run(
            ["git", "-C", repo, *args],
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            timeout=5,
            check=False,
        )
        return len([line for line in proc.stdout.splitlines() if line.strip()]) if proc.returncode == 0 else 0
    except (OSError, subprocess.TimeoutExpired):
        return 0


def analyze_code_quality(repo: str) -> dict[str, dict[str, Any]]:
    files = _repo_files(repo)
    names = [str(path).lower() for path in files]
    count = max(1, len(files))
    tests = sum(bool(re.search(r"(?:^|/)(?:tests?|specs?)/|(?:test|spec)[_.-]", name)) for name in names)
    docs = sum(name.endswith((".md", ".rst", ".txt")) for name in names)
    configs = sum(
        any(token in name for token in ("agents.md", "skill.md", "claude.md", "pyproject.toml", "package.json"))
        for name in names
    )
    ci = sum(".github/workflows" in name or "/ci/" in name for name in names)
    security = sum(any(token in name for token in ("security", "gitleaks", "dependabot", "codeql")) for name in names)
    errors = sum(any(token in name for token in ("error", "exception", "retry", "recovery")) for name in names)
    performance = sum(any(token in name for token in ("benchmark", "perf", "cache", "latency")) for name in names)
    commits = _git_count(repo, ["log", "--oneline", "-n", "100"])
    merges = _git_count(repo, ["log", "--merges", "--oneline", "-n", "100"])

    signals = {
        "commit_discipline": min(10.0, 4.0 + commits / 20.0),
        "test_quality": min(10.0, 3.0 + 35.0 * tests / count),
        "code_quality": min(10.0, 5.0 + (tests + configs) / max(1, count / 8)),
        "error_handling": min(10.0, 3.0 + errors / max(1, count / 25)),
        "security_signals": min(10.0, 3.0 + security * 1.2),
        "architecture": min(10.0, 4.0 + configs / max(1, count / 30)),
        "documentation": min(10.0, 3.0 + 30.0 * docs / count),
        "agent_config_quality": min(10.0, 3.0 + configs * 0.8),
        "infrastructure": min(10.0, 3.0 + ci * 0.7),
        "dependency_management": min(
            10.0,
            3.0 + sum(any(token in name for token in ("lock", "dependabot", "renovate")) for name in names) * 0.5,
        ),
        "git_workflow": min(10.0, 4.0 + merges / 10.0 + (2.0 if ci else 0.0)),
        "code_evolution": min(10.0, 4.0 + commits / 25.0),
        "performance_awareness": min(10.0, 3.0 + performance * 0.6),
        "production_readiness": min(10.0, 3.0 + ci * 0.5 + tests / max(1, count / 30)),
    }
    return {
        dimension: {
            "score": round(signals[dimension], 2),
            "confidence": "medium" if files else "low",
            "scorer": "local-static-v1",
            "files_considered": len(files),
        }
        for dimension in CODE_QUALITY_DIMENSIONS
    }


def _questionable_prompts(events: list[dict[str, Any]]) -> list[dict[str, str]]:
    candidates: list[dict[str, str]] = []
    vague = re.compile(
        r"^(?:do it all|everything|proceed|continue|cont|fix it|ship it|make it work|looks good|wagwan)[.! ]*$",
        re.IGNORECASE,
    )
    for event in events:
        if event.get("role") != "user":
            continue
        excerpt = event.get("excerpt", "")
        words = excerpt.split()
        if vague.match(excerpt) or (
            len(words) <= 4 and classify_decision_law(excerpt)[0] == "unclassified"
        ):
            candidates.append(
                {
                    "prompt": _short(excerpt, 120),
                    "reason": "Too little scope or acceptance evidence to determine the intended outcome.",
                }
            )
    unique: list[dict[str, str]] = []
    seen: set[str] = set()
    for item in candidates:
        key = item["prompt"].lower()
        if key not in seen:
            seen.add(key)
            unique.append(item)
    return unique[:3]


def analyze_events(events: list[dict[str, Any]], *, repo: str, project: str) -> dict[str, Any]:
    by_session: dict[str, list[dict[str, Any]]] = defaultdict(list)
    for event in events:
        by_session[str(event.get("session_id"))].append(event)

    sessions: list[dict[str, Any]] = []
    episodes: list[dict[str, Any]] = []
    decisions: list[dict[str, Any]] = []
    session_episode: dict[str, str] = {}

    for session_id, session_events in sorted(by_session.items()):
        session_events.sort(key=lambda item: (int(item.get("sequence") or 0), item["id"]))
        user_events = [event for event in session_events if event.get("role") == "user"]
        intent = _intent(session_events)
        session_project = next(
            (str(event.get("project")) for event in session_events if event.get("project")),
            project,
        )
        first_prompt = user_events[0].get("excerpt", "") if user_events else ""
        session_summary = {
            "schema": SESSION_SCHEMA,
            "id": session_id,
            "project": session_project,
            "source": session_events[0].get("source", "unknown"),
            "started_at": next((event.get("ts") for event in session_events if event.get("ts")), ""),
            "intent": intent,
            "event_count": len(session_events),
            "first_prompt_excerpt": _short(first_prompt, 240),
            "evidence_ids": [event["id"] for event in session_events[:8]],
        }
        sessions.append(session_summary)

        user_laws = [
            classify_decision_law(event.get("excerpt", ""))[0]
            for event in user_events
            if classify_decision_law(event.get("excerpt", ""))[0] != "unclassified"
        ]
        primary_law = user_laws[0] if user_laws else "general"
        day = str(session_summary.get("started_at") or "")[:10] or "undated"
        work_stream_id = _stable_id([session_project, primary_law, day])
        episode_id = _stable_id(["episode", session_id, work_stream_id])
        session_episode[session_id] = episode_id
        episode_status, _episode_evidence = _latest_outcome_evidence(session_events)
        episodes.append(
            {
                "schema": EPISODE_SCHEMA,
                "id": episode_id,
                "work_stream_id": work_stream_id,
                "project": session_project,
                "session_ids": [session_id],
                "intent": intent,
                "primary_law": primary_law,
                "outcome_status": episode_status,
                "evidence_ids": [event["id"] for event in session_events[-5:]],
            }
        )

        for event in user_events:
            law, patterns = classify_decision_law(event.get("excerpt", ""))
            if law == "unclassified":
                continue
            decisions.append(
                {
                    "schema": DECISION_SCHEMA,
                    "id": _stable_id(["decision", event["id"], law]),
                    "event_id": event["id"],
                    "session_id": session_id,
                    "episode_id": episode_id,
                    "project": session_project,
                    "sequence": event.get("sequence", 0),
                    "decision_type": _decision_type(event.get("excerpt", ""), law),
                    "law_key": law,
                    "confidence": "high" if len(patterns) > 1 else "medium",
                    "excerpt": event.get("excerpt", ""),
                    "matched_patterns": patterns,
                }
            )

    outcome_links: list[dict[str, Any]] = []
    for decision in decisions:
        outcome_links.append(_outcome_for(decision, by_session[decision["session_id"]]))

    behavior_scores = {
        axis: _axis_score(
            axis,
            events=events,
            decisions=decisions,
            links=outcome_links,
            sessions=sessions,
        )
        for axis in BEHAVIOR_AXES
    }
    dispatches = [event for event in events if event.get("event_type") == "dispatch"]
    linked = sum(link.get("status") != "no_evidence" for link in outcome_links)
    durable_repo = _durable_repository_identity(repo)
    return {
        "schema": REPORT_SCHEMA,
        "generated_at": _iso_now(),
        "repo": durable_repo,
        "project": project,
        "events_processed": len(events),
        "sessions": sessions,
        "episodes": episodes,
        "decisions": decisions,
        "outcome_links": outcome_links,
        "behavior_scores": behavior_scores,
        "code_quality": analyze_code_quality(repo),
        "questionable_prompts": _questionable_prompts(events),
        "dispatch_metadata": {
            "count": len(dispatches),
            "background": sum(bool(event.get("run_in_background")) for event in dispatches),
            "prompt_hashes": sorted(
                {str(event.get("dispatch_hash")) for event in dispatches if event.get("dispatch_hash")}
            ),
        },
        "evidence_coverage": {
            "decisions": len(decisions),
            "linked_decisions": linked,
            "unlinked_decisions": len(decisions) - linked,
            "coverage": round(linked / len(decisions), 3) if decisions else 0.0,
        },
    }


def promote_laws(
    reports: list[dict[str, Any]], *, min_episodes: int = 3, min_projects: int = 2
) -> list[dict[str, Any]]:
    support: dict[str, dict[str, set[str]]] = defaultdict(
        lambda: {"episodes": set(), "projects": set(), "evidence": set()}
    )
    for report in reports:
        default_project = str(report.get("project") or "unknown")
        for decision in report.get("decisions", []):
            if not isinstance(decision, dict):
                continue
            key = str(decision.get("law_key") or "unclassified")
            if key == "unclassified":
                continue
            support[key]["episodes"].add(str(decision.get("episode_id") or decision.get("id")))
            support[key]["projects"].add(str(decision.get("project") or default_project))
            support[key]["evidence"].add(str(decision.get("id")))
    laws: list[dict[str, Any]] = []
    for key, counts in sorted(support.items()):
        episode_count = len(counts["episodes"])
        project_count = len(counts["projects"])
        if episode_count < min_episodes or project_count < min_projects:
            continue
        confidence = min(0.99, 0.55 + episode_count * 0.07 + project_count * 0.08)
        laws.append(
            {
                "schema": LAW_SCHEMA,
                "key": key,
                "status": "active",
                "confidence": round(confidence, 3),
                "support": {"episodes": episode_count, "projects": project_count},
                "evidence_ids": sorted(counts["evidence"]),
                "guidance": LAW_GUIDANCE.get(
                    key,
                    ("Apply the recurring correction as a scoped guardrail.", "Replay the supporting workflow."),
                )[0],
                "validation": LAW_GUIDANCE.get(
                    key,
                    ("Apply the recurring correction as a scoped guardrail.", "Replay the supporting workflow."),
                )[1],
                "updated_at": _iso_now(),
            }
        )
    return laws


def _read_json(path: Path) -> Any:
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except (OSError, ValueError, TypeError):
        return None


def _atomic_json(path: Path, payload: Any) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, temporary = tempfile.mkstemp(prefix=f".{path.name}.", dir=str(path.parent))
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as handle:
            json.dump(payload, handle, indent=2, sort_keys=True, ensure_ascii=False)
            handle.write("\n")
        os.chmod(temporary, 0o600)
        os.replace(temporary, path)
    finally:
        try:
            os.unlink(temporary)
        except OSError:
            pass


def _latest_repository_reports(
    directory: Path,
    current_report: dict[str, Any],
) -> list[dict[str, Any]]:
    latest: dict[str, tuple[tuple[str, str], dict[str, Any]]] = {}
    for path in sorted(directory.glob("*.json")):
        payload = _read_json(path)
        if not isinstance(payload, dict) or payload.get("schema") != REPORT_SCHEMA:
            continue
        repository = str(payload.get("repo") or "")
        # Pre-0.2.9 local snapshots carried one shared placeholder, so they
        # cannot be attributed without mixing unrelated repositories. Ignore
        # them rather than letting anonymous historical evidence live forever.
        if not repository or repository == "[local-repo]":
            continue
        rank = (str(payload.get("generated_at") or ""), path.name)
        if repository not in latest or rank > latest[repository][0]:
            latest[repository] = (rank, payload)

    current_repository = str(current_report.get("repo") or "")
    if current_repository:
        latest[current_repository] = (
            (str(current_report.get("generated_at") or ""), ""),
            current_report,
        )
    return [latest[key][1] for key in sorted(latest)]


def merge_law_store(path: Path, laws: list[dict[str, Any]]) -> dict[str, Any]:
    path = Path(path)
    existing = _read_json(path)
    by_key: dict[str, dict[str, Any]] = {}
    if isinstance(existing, dict):
        for law in existing.get("laws", []):
            if isinstance(law, dict) and law.get("key"):
                by_key[str(law["key"])] = law
    for law in laws:
        key = str(law.get("key") or "")
        if not key:
            continue
        # ``laws`` is computed from the latest snapshot per repository, so its
        # support may legitimately decrease as stale evidence ages out.
        by_key[key] = law
    active_keys = {str(law.get("key")) for law in laws if law.get("key")}
    for key, law in by_key.items():
        if key not in active_keys and law.get("status") == "active":
            law["status"] = "retired"
            law["retired_at"] = _iso_now()
    payload = {
        "schema": "legion.learning-laws.v1",
        "updated_at": _iso_now(),
        "laws": [by_key[key] for key in sorted(by_key)],
    }
    _atomic_json(path, payload)
    return payload


def _iter_session_files(
    home: Path,
    lookback_days: int,
    max_file_mb: float,
    *,
    max_files: int = 0,
    max_total_mb: float = 0,
) -> list[Path]:
    roots = [
        home / ".claude" / "projects",
        home / ".codex" / "sessions",
        home / ".cursor",
        home / ".local" / "share" / "opencode",
        home / ".gemini",
    ]
    cutoff = (_now() - timedelta(days=lookback_days)).timestamp() if lookback_days > 0 else 0
    max_bytes = int(max_file_mb * 1024 * 1024) if max_file_mb > 0 else 0
    max_total_bytes = int(max_total_mb * 1024 * 1024) if max_total_mb > 0 else 0
    candidates: dict[Path, tuple[int, int]] = {}
    for root in roots:
        if not root.exists():
            continue
        for path in root.rglob("*.jsonl"):
            try:
                stat = path.stat()
            except OSError:
                continue
            if cutoff and stat.st_mtime < cutoff:
                continue
            # JSONL is streamed, but this cap protects accidentally selected
            # machine-generated logs in non-standard roots.
            if max_bytes and stat.st_size > max_bytes:
                continue
            candidates[path] = (stat.st_mtime_ns, stat.st_size)

    ordered = sorted(
        candidates.items(),
        key=lambda item: (-item[1][0], str(item[0])),
    )
    out: list[Path] = []
    total_bytes = 0
    for path, (_mtime_ns, size) in ordered:
        if max_files > 0 and len(out) >= max_files:
            break
        if max_total_bytes and total_bytes + size > max_total_bytes:
            continue
        out.append(path)
        total_bytes += size
    return out


def _state_dirs(repo: str, state_root: str) -> tuple[Path, Path]:
    if state_root:
        root = Path(state_root).expanduser().resolve()
        return root / "learning", root / "global" / "learning"
    state = legion_state.resolve_state(repo)
    return Path(state["project_learning_dir"]), Path(state["global_learning_dir"])


def analyze_command(args: argparse.Namespace) -> int:
    home = Path(args.home).expanduser()
    candidate_max_files = args.max_files
    candidate_max_total_mb = args.max_total_mb
    if args.repo_only:
        candidate_max_files = max(
            args.max_files,
            DEFAULT_MAX_REPO_CANDIDATE_FILES,
        )
        candidate_max_total_mb = max(
            args.max_total_mb,
            DEFAULT_MAX_REPO_CANDIDATE_TOTAL_MB,
        )
    files = _iter_session_files(
        home,
        args.lookback_days,
        args.max_file_mb,
        max_files=candidate_max_files,
        max_total_mb=candidate_max_total_mb,
    )
    events: list[dict[str, Any]] = []
    files_scanned = 0
    matched_files = 0
    matched_bytes = 0
    max_matched_bytes = (
        int(args.max_total_mb * 1024 * 1024) if args.max_total_mb > 0 else 0
    )
    for path in files:
        if args.max_events > 0 and len(events) >= args.max_events:
            break
        if args.repo_only and args.max_files > 0 and matched_files >= args.max_files:
            break
        normalized = normalize_session_file(path, home=home)
        files_scanned += 1
        if args.repo_only:
            normalized = filter_events_for_repo(normalized, args.repo)
            if not normalized:
                continue
            try:
                file_size = path.stat().st_size
            except OSError:
                continue
            if max_matched_bytes and matched_bytes + file_size > max_matched_bytes:
                continue
            matched_files += 1
            matched_bytes += file_size
        if args.max_events > 0:
            normalized = normalized[: max(0, args.max_events - len(events))]
        events.extend(normalized)
    project = safe_project_component(args.project or _project_for_cwd(args.repo))
    report = analyze_events(events, repo=args.repo, project=project)
    project_dir, global_dir = _state_dirs(args.repo, args.state_root)
    day = _now().strftime("%Y-%m-%d")
    report_path = project_dir / "reports" / f"{day}.json"
    _atomic_json(report_path, report)

    # Cross-project promotion uses one current snapshot per repository. Historical
    # daily snapshots remain readable, but cannot keep retired evidence active.
    global_reports = global_dir / "project-reports"
    global_reports.mkdir(parents=True, exist_ok=True)
    snapshot_id = legion_state.repository_project_id(args.repo)
    snapshot_path = global_reports / f"{snapshot_id}.json"
    _atomic_json(snapshot_path, report)
    reports = _latest_repository_reports(global_reports, report)
    promoted = promote_laws(reports)
    laws_path = global_dir / "laws.json"
    law_store = merge_law_store(laws_path, promoted)
    payload = {
        "schema": "legion.learning.run.v1",
        "report_path": str(report_path),
        "laws_path": str(laws_path),
        "files_scanned": files_scanned,
        "events_processed": len(events),
        "sessions": len(report["sessions"]),
        "episodes": len(report["episodes"]),
        "decisions": len(report["decisions"]),
        "promoted_laws": len(promoted),
        "active_laws": len(law_store["laws"]),
    }
    if args.json:
        print(json.dumps(payload, indent=2, sort_keys=True))
    else:
        print(
            "legion-learn: "
            f"{payload['sessions']} sessions, {payload['episodes']} episodes, "
            f"{payload['decisions']} decisions, {payload['promoted_laws']} promoted laws"
        )
        print(f"report: {report_path}")
        print(f"laws:   {laws_path}")
    return 0


def _latest_report(project_dir: Path) -> tuple[Path | None, dict[str, Any] | None]:
    paths = sorted((project_dir / "reports").glob("*.json"), reverse=True)
    for path in paths:
        payload = _read_json(path)
        if isinstance(payload, dict) and payload.get("schema") == REPORT_SCHEMA:
            return path, payload
    return None, None


def report_command(args: argparse.Namespace) -> int:
    project_dir, _global_dir = _state_dirs(args.repo, args.state_root)
    path, payload = _latest_report(project_dir)
    if not payload:
        print("legion-learn: no v2 report found", file=sys.stderr)
        return 1
    output = payload if args.full else {
        "schema": payload.get("schema"),
        "report_path": str(path),
        "generated_at": payload.get("generated_at"),
        "project": payload.get("project"),
        "sessions": len(payload.get("sessions", [])),
        "episodes": len(payload.get("episodes", [])),
        "decisions": len(payload.get("decisions", [])),
        "evidence_coverage": payload.get("evidence_coverage", {}),
        "behavior_scores": payload.get("behavior_scores", {}),
        "questionable_prompts": payload.get("questionable_prompts", []),
    }
    print(json.dumps(output, indent=2, sort_keys=True))
    return 0


def laws_command(args: argparse.Namespace) -> int:
    _project_dir, global_dir = _state_dirs(args.repo, args.state_root)
    payload = _read_json(global_dir / "laws.json")
    if not isinstance(payload, dict):
        payload = {"schema": "legion.learning-laws.v1", "laws": []}
    print(json.dumps(payload, indent=2, sort_keys=True))
    return 0


def explain_command(args: argparse.Namespace) -> int:
    _project_dir, global_dir = _state_dirs(args.repo, args.state_root)
    payload = _read_json(global_dir / "laws.json")
    laws = payload.get("laws", []) if isinstance(payload, dict) else []
    law = next((item for item in laws if isinstance(item, dict) and item.get("key") == args.key), None)
    if not law:
        print(f"legion-learn: unknown law: {args.key}", file=sys.stderr)
        return 1
    print(json.dumps(law, indent=2, sort_keys=True))
    return 0


def export_command(args: argparse.Namespace) -> int:
    project_dir, _global_dir = _state_dirs(args.repo, args.state_root)
    _path, payload = _latest_report(project_dir)
    if not payload:
        print("legion-learn: no v2 report found", file=sys.stderr)
        return 1
    # Reports are already redacted. Re-run boundary redaction recursively as a
    # defense-in-depth export gate without ever serializing and corrupting JSON.
    exported = redact_payload(payload)
    print(json.dumps(exported, indent=2, sort_keys=True, ensure_ascii=False))
    return 0


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(prog="legion-learn")
    sub = parser.add_subparsers(dest="command", required=True)

    def common(command: argparse.ArgumentParser) -> None:
        command.add_argument("--repo", default=os.getcwd())
        command.add_argument("--state-root", default="")

    analyze = sub.add_parser("analyze", help="build a redacted evidence-linked learning report")
    common(analyze)
    analyze.add_argument("--home", default="~")
    analyze.add_argument("--project", default="")
    analyze.add_argument("--lookback-days", type=int, default=3)
    analyze.add_argument("--max-file-mb", type=float, default=8.0)
    analyze.add_argument("--max-files", type=int, default=DEFAULT_MAX_SESSION_FILES)
    analyze.add_argument(
        "--max-total-mb",
        type=float,
        default=DEFAULT_MAX_SESSION_TOTAL_MB,
    )
    analyze.add_argument("--max-events", type=int, default=DEFAULT_MAX_EVENTS)
    analyze.add_argument(
        "--repo-only",
        action="store_true",
        help="keep only sessions whose cwd/remote provenance matches --repo",
    )
    analyze.add_argument("--json", action="store_true")
    analyze.set_defaults(func=analyze_command)

    report = sub.add_parser("report", help="show the latest project learning report")
    common(report)
    report.add_argument("--full", action="store_true")
    report.set_defaults(func=report_command)

    laws = sub.add_parser("laws", help="show promoted global learning laws")
    common(laws)
    laws.set_defaults(func=laws_command)

    explain = sub.add_parser("explain", help="show support and evidence for one law")
    common(explain)
    explain.add_argument("key")
    explain.set_defaults(func=explain_command)

    export = sub.add_parser("export", help="export the latest already-redacted report")
    common(export)
    export.set_defaults(func=export_command)

    args = parser.parse_args(argv)
    return int(args.func(args))


if __name__ == "__main__":
    raise SystemExit(main())
