"""Append-only session log that Legion owns.

v1 harvested other harnesses' transcripts into bounded `excerpt` strings. That
records that something happened without recording what, so a delegated run could
not be replayed and "what did the model actually see?" had no answer.

This module writes the log instead of scraping one, and enforces the invariant
that makes it worth having: anything model-visible must be reconstructable from
the log alone. If a request cannot be rebuilt from what was appended, the log is
not evidence, it is a summary that looks like evidence.

Stdlib only, importable without side effects, matching the other scripts here.
"""

from __future__ import annotations

import hashlib
import json
import os
import re
import uuid
from datetime import datetime, timezone
from typing import Any, Iterable, Iterator

SCHEMA = "legion.session-event.v2"

# ACP SessionUpdate variants, plus the turn/step boundaries ACP carries at
# protocol level. Kept in one place so the writer and the schema cannot drift.
TURN_EVENTS = ("turn_start", "turn_end", "step_start", "step_end")
MESSAGE_EVENTS = (
    "user_message",
    "user_message_chunk",
    "agent_message",
    "agent_message_chunk",
    "agent_thought",
    "agent_thought_chunk",
)
TOOL_EVENTS = (
    "tool_call_update",
    "tool_call_content_chunk",
    "terminal_update",
    "terminal_output_chunk",
)
STATE_EVENTS = (
    "plan_update",
    "state_update",
    "usage_update",
    "available_commands_update",
    "config_option_update",
    "session_info_update",
)
EVENT_TYPES = frozenset(TURN_EVENTS + MESSAGE_EVENTS + TOOL_EVENTS + STATE_EVENTS)

# Events whose content reaches a model request. These carry the invariant: a
# reader must be able to rebuild the request from them alone.
MODEL_VISIBLE_TYPES = frozenset(
    {
        "user_message",
        "user_message_chunk",
        "agent_message",
        "agent_message_chunk",
        "tool_call_update",
        "tool_call_content_chunk",
    }
)

_SECRET_PATTERNS = (
    re.compile(r"\b(sk-[A-Za-z0-9_-]{16,})"),
    re.compile(r"\b(gh[pousr]_[A-Za-z0-9]{16,})"),
    re.compile(r"\b(AKIA[0-9A-Z]{12,})"),
)


class SessionLogError(RuntimeError):
    """The log cannot honour its contract."""


def _now() -> str:
    return datetime.now(timezone.utc).isoformat(timespec="milliseconds").replace("+00:00", "Z")


def session_log_path(log_root: str, session_id: str) -> str:
    safe = re.sub(r"[^A-Za-z0-9._-]+", "-", session_id).strip("-") or "session"
    return os.path.join(os.path.expanduser(log_root), "sessions", f"{safe}.jsonl")


def redact(text: str) -> tuple[str, bool]:
    """Strip obvious credentials, reporting whether anything was removed.

    The flag matters more than the redaction: an event that quietly lost content
    is indistinguishable from a faithful one, and a log you cannot trust to be
    complete is not evidence. Callers record `redacted` so the gap is visible.
    """
    out = text
    for pattern in _SECRET_PATTERNS:
        out = pattern.sub("[redacted]", out)
    return out, out != text


class SessionLog:
    """Append-only writer for one session."""

    def __init__(self, log_root: str, session_id: str, *, run_id: str | None = None,
                 trace_id: str | None = None) -> None:
        self.path = session_log_path(log_root, session_id)
        self.session_id = session_id
        self.run_id = run_id
        self.trace_id = trace_id
        os.makedirs(os.path.dirname(self.path), exist_ok=True)
        self._sequence = self._resume_sequence()

    def _resume_sequence(self) -> int:
        """Continue an existing log rather than restarting its numbering.

        Two processes appending from sequence 0 would produce a log whose order
        cannot be recovered, which defeats the point of an append-only record.
        """
        highest = -1
        if os.path.exists(self.path):
            for event in read_events(self.path):
                value = event.get("sequence")
                if isinstance(value, int) and value > highest:
                    highest = value
        return highest + 1

    def append(self, event_type: str, content: Any = None, *,
               executor: str | None = None, model_visible: bool | None = None) -> dict[str, Any]:
        if event_type not in EVENT_TYPES:
            raise SessionLogError(
                f"unknown event type {event_type!r}; the vocabulary is fixed so a log "
                f"stays readable by anything that speaks ACP SessionUpdate"
            )
        if model_visible is None:
            model_visible = event_type in MODEL_VISIBLE_TYPES

        redacted = False
        if isinstance(content, str):
            content, redacted = redact(content)

        event = {
            "schema": SCHEMA,
            "id": uuid.uuid4().hex,
            "session_id": self.session_id,
            "run_id": self.run_id,
            "trace_id": self.trace_id,
            "sequence": self._sequence,
            "ts": _now(),
            "type": event_type,
            "executor": executor,
            "content": content,
            "model_visible": bool(model_visible),
            "redacted": redacted,
        }
        self._sequence += 1
        with open(self.path, "a", encoding="utf-8") as handle:
            handle.write(json.dumps(event, sort_keys=True) + "\n")
        return event


def read_events(path: str) -> Iterator[dict[str, Any]]:
    """Yield events in append order, skipping unreadable lines.

    A truncated final line is normal after a crash mid-append and must not make
    the whole log unreadable -- losing one event is recoverable, losing the
    session is not.
    """
    if not os.path.exists(path):
        return
    with open(path, encoding="utf-8") as handle:
        for line in handle:
            line = line.strip()
            if not line:
                continue
            try:
                event = json.loads(line)
            except ValueError:
                continue
            if isinstance(event, dict):
                yield event


def derive_model_history(events: Iterable[dict[str, Any]]) -> list[dict[str, Any]]:
    """Project the model-visible history from the log.

    This is the whole point of owning the log: the request a model received is
    derived from what was recorded, so the record cannot silently disagree with
    what was sent.
    """
    history: list[dict[str, Any]] = []
    for event in sorted(events, key=lambda item: item.get("sequence", 0)):
        if not event.get("model_visible"):
            continue
        history.append({
            "type": event.get("type"),
            "content": event.get("content"),
            "sequence": event.get("sequence"),
            "redacted": bool(event.get("redacted")),
        })
    return history


def request_digest(history: Iterable[dict[str, Any]]) -> str:
    """Stable digest of a derived history, for asserting reconstruction."""
    payload = json.dumps(list(history), sort_keys=True, ensure_ascii=False)
    return hashlib.sha256(payload.encode("utf-8")).hexdigest()


def assert_model_visible_is_logged(sent_history: Iterable[dict[str, Any]],
                                   path: str) -> None:
    """Fail loudly when what was sent cannot be rebuilt from the log.

    Documenting this invariant is not enforcing it. An assertion at the point of
    divergence is the difference between a log that is evidence and a log that
    merely looks like one -- and the failure it catches (a request assembled
    from something the log never saw) is invisible by construction otherwise.
    """
    sent = list(sent_history)
    derived = derive_model_history(read_events(path))
    if request_digest(sent) != request_digest(derived):
        raise SessionLogError(
            "model-visible content was sent that the session log cannot reproduce: "
            f"{len(sent)} sent vs {len(derived)} logged in {path}"
        )
