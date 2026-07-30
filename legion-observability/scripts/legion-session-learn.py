#!/usr/bin/env python3
"""Mine recent agent sessions into Legion self-learning outcomes.

This is the layer above "the user noticed a pattern". It scans Claude memories,
Claude/Codex/Cursor JSONL sessions, extracts paragraphs that look like gotchas or
review findings, classifies them into reusable guardrail categories, and can
record those as `legion.outcome.v1` records for `legion-self-learn run`.
"""
from __future__ import annotations

import argparse
from functools import lru_cache
import hashlib
import json
import os
import re
import subprocess
import sys
from dataclasses import dataclass, field
from datetime import datetime, timedelta, timezone
from pathlib import Path
from typing import Any

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import legion_state  # noqa: E402

OUTCOME_SCHEMA = "legion.outcome.v1"
DEFAULT_LOG_ROOT = ""
MAX_BLOCK_CHARS = 20000
DEFAULT_SESSION_LIMIT = 100
DEFAULT_ROLES = {"assistant", "unknown", "user"}
VALID_HARNESSES = {"claude", "codex", "cursor"}
VALID_ROLES = {"assistant", "developer", "system", "tool", "unknown", "user"}
VALID_SOURCE_KINDS = {
    "claude-memory",
    "claude-plan",
    "claude-project-note",
    "claude-session",
    "codex-session",
    "cursor-note",
    "cursor-session",
}
BENCHMARK_TOKEN = re.compile(r"(?:^|[-_.])(bench(?:mark)?|eval|fixture|test)(?:$|[-_.])", re.I)
CREDENTIAL_ASSIGNMENT = re.compile(
    r"(?i)\b((?:[a-z0-9]+[_-])*(?:api[_-]?key|access[_-]?key|"
    r"access[_-]?token|auth[_-]?token|client[_-]?(?:secret|token|key)|"
    r"private[_-]?key|secret[_-]?access[_-]?key|password|passwd|"
    r"credential))\b([\"']?\s*[:=]\s*[\"']?)([^\s,;\"']+)"
)
PEM_PRIVATE_KEY = re.compile(
    r"-----BEGIN [A-Z0-9 ]*PRIVATE KEY-----.*?"
    r"-----END [A-Z0-9 ]*PRIVATE KEY-----",
    re.DOTALL,
)
AUTHENTICATED_URL = re.compile(
    r"(?i)\b([a-z][a-z0-9+.-]*://)([^/\s:@]+):([^@\s/]+)@"
)
BEARER_TOKEN = re.compile(r"(?i)\bbearer\s+[a-z0-9._~+/=-]{12,}")
PROVIDER_TOKEN = re.compile(
    r"\b(?:sk-[a-zA-Z0-9_-]{12,}|ghp_[a-zA-Z0-9]{12,}|"
    r"github_pat_[a-zA-Z0-9_]{12,}|AKIA[A-Z0-9]{12,})\b"
)
JWT_TOKEN = re.compile(
    r"\beyJ[a-zA-Z0-9_-]{8,}\.[a-zA-Z0-9_-]{8,}\.[a-zA-Z0-9_-]{8,}\b"
)
OPAQUE_TOKEN = re.compile(r"\b[a-zA-Z0-9_+/=-]{40,}\b")
EMAIL_ADDRESS = re.compile(r"\b[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}\b", re.I)


@dataclass
class SourceInfo:
    path: Path
    harness: str
    source_kind: str
    source_id: str = ""
    cwd: str = ""
    repository_urls: set[str] = field(default_factory=set)
    session_ids: set[str] = field(default_factory=set)
    subagent: bool = False
    benchmark: bool = False


@dataclass
class RepoScope:
    path: Path
    repo_id: str
    repository_urls: set[str] = field(default_factory=set)

RULES = [
    {
        "category": "seam-consumption",
        "entity": "skill:legion-orchestrate",
        "severity": "high",
        "summary": (
            "Require consumption proof for declared seams: an interface is not wired until "
            "a domain path calls it and telemetry/validation proves it."
        ),
        "patterns": [
            r"seams? (are )?wired but dead",
            r"zero domain callers",
            r"defined\+tested but",
            r"not actually consumed",
            r"no real spans? flow",
            r"span sink is wrong",
            r"status .*isn.?t in the canonical enum",
        ],
    },
    {
        "category": "provider-truth-preflight",
        "entity": "skill:legion-orchestrate",
        "severity": "high",
        "summary": (
            "Before deploy or extraction work, verify provider truth directly: Vercel "
            "project root/build settings, aliases, auth token source, basePath, and "
            "private-package access can differ from repo assumptions."
        ),
        "patterns": [
            r"rootDirectory",
            r"buildCommand",
            r"bare .*vercel\\.app .*different",
            r"stale.*VERCEL_TOKEN",
            r"private .*packages?.*401",
            r"GitHub Packages.*403",
            r"preview deploys?.*SSO",
            r"basePath",
            r"Vercel .*Root Directory",
            r"doesn.?t apply",
        ],
    },
    {
        "category": "ci-admin-bypass",
        "entity": "skill:legion-orchestrate",
        "severity": "high",
        "summary": (
            "When admin or bypass merge is used, prove required checks are actually green; "
            "do not treat bypassing review as bypassing CI health."
        ),
        "patterns": [
            r"admin bypass",
            r"admin-merg",
            r"checks? .*GREEN",
            r"silently red",
            r"review required",
            r"required checks?",
            r"validate-installer-coverage",
            r"mergeStateStatus",
        ],
    },
    {
        "category": "visual-delivery-gate",
        "entity": "skill:legion-orchestrate",
        "severity": "medium",
        "summary": (
            "For cinematic/landing/UI work, require visual acceptance evidence across "
            "desktop, mobile, reduced motion, and live deployment before declaring done."
        ),
        "patterns": [
            r"cinematic landing",
            r"Higgsfield",
            r"hero video",
            r"reduced-motion",
            r"screenshot",
            r"viewport",
            r"mobile",
            r"visual",
            r"landing.*feel premium",
            r"scroll-scrubbed",
        ],
    },
    {
        "category": "skill-taxonomy-drift",
        "entity": "plugin:legion-setup",
        "severity": "medium",
        "summary": (
            "New skills must be classified and stamped in the marketplace taxonomy; "
            "otherwise plugin validation and installer coverage fail after merge-base drift."
        ),
        "patterns": [
            r"unclassified skill",
            r"skill taxonomy",
            r"apply-skill-taxonomy",
            r"kind: ability",
            r"validate-plugins.*taxonomy",
        ],
    },
    {
        "category": "repo-extraction-sweep",
        "entity": "skill:legion-orchestrate",
        "severity": "high",
        "summary": (
            "For app extraction or deletion, run a structured sweep: remaining refs, "
            "reverse deps, fixed-version/release config, deploy workflows, auth origins, "
            "lockfile provenance, and provider config."
        ),
        "patterns": [
            r"extraction diff",
            r"missed monorepo references",
            r"release/versioning pitfalls",
            r"deploy/config breakage",
            r"remaining .* refs",
            r"reverse deps",
            r"changeset",
            r"bun\\.lock",
            r"workspace depend",
            r"trusted origins",
        ],
    },
    {
        "category": "review-terminal-integrity",
        "entity": "plugin:legion-router",
        "severity": "high",
        "summary": (
            "Independent review must finish with a schema-valid terminal verdict; "
            "interruption, timeout, or malformed output must retry within bounds and fail closed."
        ),
        "patterns": [
            r"review was interrupted",
            r"review .*timed out",
            r"missing .*review verdict",
            r"malformed .*review verdict",
            r"unparseable .*review",
            r"review .*fail(?:ed)? open",
        ],
    },
    {
        "category": "validation-environment-drift",
        "entity": "plugin:legion-run",
        "severity": "high",
        "summary": (
            "Run validation in a bounded, hermetic environment: inherited Legion state, "
            "optional network probes, or stalled suites must not obscure the terminal gate."
        ),
        "patterns": [
            r"inherited .*LEGION_",
            r"environment leakage",
            r"network-only test",
            r"optional .*network test",
            r"(suite|test|validation) .*stall",
            r"validation .*not run",
            r"clean .*rerun .*stalled",
        ],
    },
    {
        "category": "worktree-application-lifecycle",
        "entity": "plugin:legion-router",
        "severity": "high",
        "summary": (
            "Preflight worktree capability and preserve stable application receipts; "
            "never hide caller changes, fail open into the caller tree, or return dead paths."
        ),
        "patterns": [
            r"worktree_setup_failed",
            r"worktree creation .*fail",
            r"(workspace|worktree) .*read-only",
            r"diff does not apply",
            r"worktree .*gone",
            r"(deleted|removed) worktree",
            r"uncommitted .*invisible",
            r"cannot see uncommitted",
        ],
    },
    {
        "category": "legion-policy-bypass",
        "entity": "plugin:legion-setup",
        "severity": "high",
        "summary": (
            "Repository instructions must make Legion-first execution observable across "
            "harnesses and report a blocker instead of silently invoking raw provider CLIs."
        ),
        "patterns": [
            r"bypass(?:ed|ing)? legion",
            r"did not use legion",
            r"legion .*not loaded",
            r"missed .*AGENTS\\.md",
            r"AGENTS\\.md .*not (loaded|read)",
            r"raw (codex|claude|opencode|cursor) .*instead",
            r"legion unavailable .*continued",
        ],
    },
    {
        "category": "user-correction-feedback",
        "entity": "plugin:legion-observability",
        "severity": "medium",
        "roles": ["user"],
        "summary": (
            "Treat explicit user corrections as self-learning feedback: record the "
            "miss, verify the concrete source of truth, and turn repeated misses into "
            "guardrails before similar docs/routing/orchestration work."
        ),
        "patterns": [
            r"\b(you|u) should have\b",
            r"\b(you|u) (missed|forgot|linked|credited|used) (the )?wrong\b",
            r"\bwrong (repo|paper|link|credit|attribution|source)\b",
            r"\bnot (the )?(right|correct) (repo|paper|link|credit|attribution|source)\b",
            r"\bnot what i meant\b",
            r"\bthat(?:'s| is) wrong\b",
            r"\bdid we even refer to\b",
            r"\bi thought\b.*\b(from|was|came from|based on)\b",
            r"\bhow (the hell|did) .* happen(?:ed)?\b",
            r"\bis .*learn(?:ing|in) from this\b",
            r"\bthis (should|needs?) .* learn\b",
        ],
    },
]


def _utc_now() -> datetime:
    return datetime.now(timezone.utc)


def _stable_id(parts: list[Any]) -> str:
    raw = json.dumps(parts, sort_keys=True, ensure_ascii=True, default=str)
    return hashlib.sha256(raw.encode("utf-8")).hexdigest()[:16]


def _short(text: str, limit: int) -> str:
    collapsed = " ".join((text or "").split())
    return collapsed if len(collapsed) <= limit else collapsed[: limit - 3].rstrip() + "..."


def _normalized_text(text: str) -> str:
    return " ".join((text or "").split()).casefold()


def _redact_text(text: str, home: Path | None = None) -> str:
    redacted = text or ""
    if home is not None:
        home_text = str(home.expanduser())
        if home_text and home_text != "/":
            redacted = redacted.replace(home_text, "~")
    redacted = PEM_PRIVATE_KEY.sub("<redacted-private-key>", redacted)
    redacted = AUTHENTICATED_URL.sub(
        lambda match: f"{match.group(1)}<redacted>:<redacted>@",
        redacted,
    )
    redacted = CREDENTIAL_ASSIGNMENT.sub(
        lambda match: f"{match.group(1)}{match.group(2)}<redacted>",
        redacted,
    )
    for pattern in (BEARER_TOKEN, PROVIDER_TOKEN, JWT_TOKEN, OPAQUE_TOKEN):
        redacted = pattern.sub("<redacted-secret>", redacted)
    redacted = EMAIL_ADDRESS.sub("<redacted-email>", redacted)
    return redacted


def _relative_source_path(path: Path, home: Path) -> str:
    try:
        return str(path.relative_to(home))
    except ValueError:
        return path.name


def _cutoff(days: int) -> float:
    if days <= 0:
        return 0.0
    return (_utc_now() - timedelta(days=days)).timestamp()


def _normalize_repository_url(value: str) -> str:
    url = (value or "").strip().removesuffix("/")
    if not url:
        return ""
    if re.match(r"^[^/@\s]+@[^:\s]+:", url):
        host_path = url.split("@", 1)[1]
        host, path = host_path.split(":", 1)
        url = f"{host}/{path}"
    else:
        url = re.sub(r"^[a-z][a-z0-9+.-]*://", "", url, flags=re.I)
        url = re.sub(r"^[^/@\s]+@", "", url)
    return url.removesuffix(".git").casefold()


def _repo_scope(repo: Path | None) -> RepoScope | None:
    if repo is None:
        return None
    path = repo.expanduser().resolve()
    repository_urls = set(_repository_urls_for_path(str(path)))
    identity = sorted(repository_urls) or [str(path)]
    return RepoScope(
        path=path,
        repo_id=_stable_id(["repo", identity]),
        repository_urls=repository_urls,
    )


@lru_cache(maxsize=512)
def _repository_urls_for_path(path_text: str) -> frozenset[str]:
    repository_urls: set[str] = set()
    try:
        proc = subprocess.run(
            [
                "git",
                "-C",
                path_text,
                "config",
                "--get-regexp",
                r"^remote\..*\.url$",
            ],
            check=False,
            capture_output=True,
            text=True,
            timeout=5,
        )
        for line in proc.stdout.splitlines():
            _, _, value = line.partition(" ")
            normalized = _normalize_repository_url(value)
            if normalized:
                repository_urls.add(normalized)
    except (OSError, subprocess.SubprocessError):
        pass
    return frozenset(repository_urls)


def _path_source_kind(path: Path, home: Path) -> tuple[str, str]:
    try:
        relative = path.relative_to(home)
    except ValueError:
        relative = path
    parts = relative.parts
    if len(parts) >= 2 and parts[0] == ".codex" and parts[1] == "sessions":
        return "codex", "codex-session"
    if len(parts) >= 2 and parts[0] == ".claude" and parts[1] == "plans":
        return "claude", "claude-plan"
    if len(parts) >= 2 and parts[0] == ".claude" and parts[1] == "projects":
        if path.suffix == ".jsonl":
            return "claude", "claude-session"
        if "memory" in {part.casefold() for part in parts}:
            return "claude", "claude-memory"
        return "claude", "claude-project-note"
    if parts and parts[0] == ".cursor":
        if path.suffix in {".json", ".jsonl", ".log"}:
            return "cursor", "cursor-session"
        return "cursor", "cursor-note"
    return "", ""


def _metadata_strings(obj: dict[str, Any], *keys: str) -> list[str]:
    values: list[str] = []
    containers = [obj]
    for name in ("payload", "message", "metadata", "git"):
        value = obj.get(name)
        if isinstance(value, dict):
            containers.append(value)
            nested_git = value.get("git")
            if isinstance(nested_git, dict):
                containers.append(nested_git)
    for container in containers:
        for key in keys:
            value = container.get(key)
            if isinstance(value, str) and value.strip():
                values.append(value.strip())
    return values


def _inspect_jsonl_metadata(info: SourceInfo, max_lines: int = 200) -> None:
    try:
        with info.path.open(encoding="utf-8", errors="ignore") as handle:
            for index, line in enumerate(handle):
                if index >= max_lines:
                    break
                try:
                    obj = json.loads(line)
                except ValueError:
                    continue
                if not isinstance(obj, dict):
                    continue
                cwd_values = _metadata_strings(obj, "cwd", "repo_root", "workspace_root")
                if cwd_values and not info.cwd:
                    info.cwd = cwd_values[0]
                for value in _metadata_strings(
                    obj, "repository_url", "repositoryUrl", "repo_url", "remote_url"
                ):
                    normalized = _normalize_repository_url(value)
                    if normalized:
                        info.repository_urls.add(normalized)
                info.session_ids.update(
                    _metadata_strings(
                        obj,
                        "session_id",
                        "sessionId",
                        "thread_id",
                        "threadId",
                    )
                )
                if str(obj.get("type") or "").lower() == "session_meta":
                    info.session_ids.update(_metadata_strings(obj, "id"))
                if _metadata_strings(obj, "agent_path", "parent_thread_id", "parentThreadId"):
                    info.subagent = True
                if any(
                    value is True
                    for value in (
                        obj.get("isSidechain"),
                        obj.get("is_sidechain"),
                        (obj.get("payload") or {}).get("isSidechain")
                        if isinstance(obj.get("payload"), dict)
                        else False,
                    )
                ):
                    info.subagent = True
                provenance = _metadata_strings(
                    obj, "originator", "source", "source_kind", "run_kind", "mode"
                )
                if any(BENCHMARK_TOKEN.search(value) for value in provenance):
                    info.benchmark = True
    except OSError:
        return


def _source_info(path: Path, home: Path) -> SourceInfo:
    harness, source_kind = _path_source_kind(path, home)
    try:
        relative = path.relative_to(home)
    except ValueError:
        relative = path
    path_tokens = {part.casefold() for part in relative.parts}
    info = SourceInfo(
        path=path,
        harness=harness,
        source_kind=source_kind,
        subagent="subagents" in path_tokens or "subagent" in path_tokens,
        benchmark=bool(
            path_tokens.intersection({"bench", "benchmark", "benchmarks", "eval", "fixtures"})
        ),
    )
    if path.suffix in {".json", ".jsonl"}:
        _inspect_jsonl_metadata(info)
    source_identity = sorted(info.session_ids) or [_relative_source_path(path, home)]
    info.source_id = _stable_id([info.harness, info.source_kind, source_identity])
    return info


def _path_within(path: Path, parent: Path) -> bool:
    try:
        path.relative_to(parent)
        return True
    except ValueError:
        return False


def _source_matches_repo(info: SourceInfo, scope: RepoScope, home: Path) -> bool:
    if info.cwd:
        try:
            cwd = Path(info.cwd).expanduser().resolve()
            if cwd == scope.path or _path_within(cwd, scope.path):
                return True
            if scope.repository_urls.intersection(
                _repository_urls_for_path(str(cwd))
            ):
                return True
        except (OSError, RuntimeError):
            pass
    if scope.repository_urls and scope.repository_urls.intersection(info.repository_urls):
        return True
    if info.source_kind in {"claude-memory", "claude-project-note", "claude-session"}:
        encoded = str(scope.path).replace(os.sep, "-")
        try:
            relative = info.path.relative_to(home / ".claude" / "projects")
        except ValueError:
            return False
        if relative.parts and relative.parts[0] == encoded:
            return True
    return False


def _iter_files(home: Path, days: int, max_file_mb: float) -> tuple[list[Path], int]:
    cutoff = _cutoff(days)
    max_bytes = int(max_file_mb * 1024 * 1024) if max_file_mb > 0 else 0
    roots = [
        home / ".claude" / "projects",
        home / ".claude" / "plans",
        home / ".codex" / "sessions",
        home / ".cursor",
    ]
    suffixes = {".md", ".txt", ".jsonl", ".json", ".log"}
    out: list[Path] = []
    skipped = 0
    for root in roots:
        if not root.exists():
            continue
        for path in root.rglob("*"):
            if not path.is_file() or path.suffix not in suffixes:
                continue
            try:
                stat = path.stat()
                if cutoff and stat.st_mtime < cutoff:
                    continue
                if max_bytes and stat.st_size > max_bytes and path.suffix != ".jsonl":
                    skipped += 1
                    continue
            except OSError:
                continue
            out.append(path)
    def mtime(path: Path) -> float:
        try:
            return path.stat().st_mtime
        except OSError:
            return 0.0

    return sorted(out, key=mtime, reverse=True), skipped


def _content_text(content: Any, *, include_tool_results: bool = False) -> str:
    if isinstance(content, str):
        return content
    if isinstance(content, list):
        parts: list[str] = []
        for item in content:
            if isinstance(item, dict):
                if item.get("type") in {"input_text", "output_text", "text"}:
                    parts.append(str(item.get("text") or ""))
                elif item.get("type") == "tool_result" and include_tool_results:
                    parts.append(str(item.get("content") or ""))
            else:
                parts.append(str(item))
        return "\n".join(parts)
    if isinstance(content, dict):
        for key in ("message", "content", "text", "summary"):
            value = content.get(key)
            text = _content_text(value, include_tool_results=include_tool_results)
            if text:
                return text
    return ""


def _message_role(obj: dict[str, Any]) -> str:
    message = obj.get("message") if isinstance(obj.get("message"), dict) else {}
    if isinstance(message, dict) and isinstance(message.get("role"), str):
        return str(message["role"]).lower()
    if isinstance(obj.get("role"), str):
        return str(obj["role"]).lower()
    payload = obj.get("payload") if isinstance(obj.get("payload"), dict) else {}
    payload_type = str(payload.get("type") or "").lower()
    if payload_type == "user_message":
        return "user"
    if payload_type == "agent_message":
        return "assistant"
    if payload_type in {"tool", "tool_result", "function_call_output"}:
        return "tool"
    if isinstance(payload.get("role"), str):
        return str(payload["role"]).lower()
    record_type = str(obj.get("type") or "").lower()
    if record_type in {"assistant", "developer", "system", "tool", "user"}:
        return record_type
    return ""


def _message_text(obj: dict[str, Any], *, include_tool_results: bool = False) -> str:
    message = obj.get("message") if isinstance(obj.get("message"), dict) else {}
    content = message.get("content") if isinstance(message, dict) else None
    text = _content_text(content, include_tool_results=include_tool_results)
    if text:
        return text
    payload = obj.get("payload") if isinstance(obj.get("payload"), dict) else {}
    text = _content_text(payload, include_tool_results=include_tool_results)
    if text:
        return text
    for key in ("content", "text", "summary", "message"):
        text = _content_text(obj.get(key), include_tool_results=include_tool_results)
        if text:
            return text
    return str(obj.get("summary") or "")


def _record_is_message(obj: dict[str, Any], *, include_tool_results: bool) -> bool:
    record_type = str(obj.get("type") or "").lower()
    payload = obj.get("payload") if isinstance(obj.get("payload"), dict) else {}
    payload_type = str(payload.get("type") or "").lower()
    if record_type == "event_msg":
        return payload_type in {"agent_message", "user_message"} or (
            include_tool_results and payload_type in {"tool", "tool_result"}
        )
    if record_type == "response_item":
        return str(payload.get("type") or "").lower() == "message"
    if record_type in {
        "file-history-snapshot",
        "session_meta",
        "system",
        "turn_context",
        "world_state",
    }:
        return record_type == "system"
    if payload_type in {"function_call", "function_call_output", "tool", "tool_result"}:
        return include_tool_results
    return True


def _extract_records(path: Path, *, include_tool_results: bool = False) -> list[dict[str, str]]:
    if path.suffix == ".jsonl":
        records: list[dict[str, str]] = []
        try:
            with path.open(encoding="utf-8", errors="ignore") as handle:
                for line in handle:
                    try:
                        payload = json.loads(line)
                    except ValueError:
                        continue
                    if isinstance(payload, dict):
                        if not _record_is_message(
                            payload, include_tool_results=include_tool_results
                        ):
                            continue
                        block = _message_text(
                            payload, include_tool_results=include_tool_results
                        )
                        if block:
                            records.append(
                                {
                                    "text": block[:MAX_BLOCK_CHARS],
                                    "role": _message_role(payload),
                                }
                            )
        except OSError:
            return []
        return records

    try:
        text = path.read_text(encoding="utf-8", errors="ignore")
    except OSError:
        return []
    if path.suffix == ".json":
        try:
            payload = json.loads(text)
        except ValueError:
            return []
        if isinstance(payload, dict):
            if not _record_is_message(payload, include_tool_results=include_tool_results):
                return []
            block = _message_text(payload, include_tool_results=include_tool_results)
            return [{"text": block[:MAX_BLOCK_CHARS], "role": _message_role(payload)}]
        return []
    return [
        {"text": part[:MAX_BLOCK_CHARS], "role": ""}
        for part in re.split(r"\n\s*\n", text)
        if part.strip()
    ]


def _extract_blocks(path: Path) -> list[str]:
    return [record["text"] for record in _extract_records(path)]


def _matches_query(block: str, queries: list[str]) -> bool:
    if not queries:
        return True
    lower = block.lower()
    return any(query.lower() in lower for query in queries)


def classify_block(block: str, role: str = "") -> list[dict[str, Any]]:
    hits: list[dict[str, Any]] = []
    for rule in RULES:
        roles = {str(item).lower() for item in rule.get("roles", [])}
        if roles and role.lower() not in roles:
            continue
        matched = [
            pat
            for pat in rule["patterns"]
            if re.search(str(pat), block, flags=re.IGNORECASE | re.DOTALL)
        ]
        if matched:
            hits.append({"rule": rule, "patterns": matched})
    return hits


def _normalized_role(role: str) -> str:
    value = (role or "").strip().casefold()
    return value if value in VALID_ROLES else "unknown"


def _evidence_item(
    *,
    info: SourceInfo,
    record_id: str,
    role: str,
    matched_patterns: list[str],
    block: str,
    home: Path,
    show_evidence: bool,
) -> dict[str, Any]:
    item: dict[str, Any] = {
        "evidence_id": _stable_id(["evidence", info.source_id, record_id]),
        "source_id": info.source_id,
        "source_kind": info.source_kind,
        "harness": info.harness,
        "role": role,
        "summary": (
            f"Matched {len(matched_patterns)} guardrail signal(s) in a "
            f"{info.source_kind} {role} record."
        ),
    }
    if show_evidence:
        item["source_path"] = _relative_source_path(info.path, home)
        item["snippet"] = _short(_redact_text(block, home), 700)
    return item


def scan(
    home: Path,
    *,
    days: int = 3,
    queries: list[str] | None = None,
    limit: int = 5,
    max_file_mb: float = 8.0,
    repo: Path | None = None,
    harnesses: set[str] | None = None,
    roles: set[str] | None = None,
    source_kinds: set[str] | None = None,
    session_limit: int = DEFAULT_SESSION_LIMIT,
    include_subagents: bool = False,
    include_benchmarks: bool = False,
    include_tool_results: bool = False,
    show_evidence: bool = False,
) -> dict[str, Any]:
    home = home.expanduser().resolve()
    queries = queries or []
    harnesses = {item.casefold() for item in (harnesses or set())}
    roles = {_normalized_role(item) for item in (roles or DEFAULT_ROLES)}
    source_kinds = {item.casefold() for item in (source_kinds or set())}
    scope = _repo_scope(repo)
    grouped: dict[str, dict[str, Any]] = {}
    files, skipped = _iter_files(home, days, max_file_mb)
    sources: list[SourceInfo] = []
    filter_counts = {
        "benchmark": 0,
        "harness": 0,
        "repo": 0,
        "source_kind": 0,
        "subagent": 0,
    }
    for path in files:
        info = _source_info(path, home)
        if harnesses and info.harness not in harnesses:
            filter_counts["harness"] += 1
            continue
        if source_kinds and info.source_kind not in source_kinds:
            filter_counts["source_kind"] += 1
            continue
        if info.subagent and not include_subagents:
            filter_counts["subagent"] += 1
            continue
        if info.benchmark and not include_benchmarks:
            filter_counts["benchmark"] += 1
            continue
        if scope is not None and not _source_matches_repo(info, scope, home):
            filter_counts["repo"] += 1
            continue
        sources.append(info)
    limited = 0
    if session_limit > 0 and len(sources) > session_limit:
        limited = len(sources) - session_limit
        sources = sources[:session_limit]

    records_scanned = 0
    records_filtered_by_role = 0
    records_deduplicated = 0
    seen_records: set[str] = set()
    for info in sources:
        for record in _extract_records(
            info.path, include_tool_results=include_tool_results
        ):
            records_scanned += 1
            role = _normalized_role(record.get("role", ""))
            if role not in roles:
                records_filtered_by_role += 1
                continue
            block = record["text"]
            record_id = _stable_id(["record", role, _normalized_text(block)])
            deduplication_id = _stable_id([info.source_id, record_id])
            if deduplication_id in seen_records:
                records_deduplicated += 1
                continue
            seen_records.add(deduplication_id)
            if not _matches_query(block, queries):
                continue
            for hit in classify_block(block, role=role):
                rule = hit["rule"]
                category = str(rule["category"])
                group = grouped.setdefault(
                    category,
                    {
                        "category": category,
                        "entity": rule["entity"],
                        "severity": rule["severity"],
                        "summary": rule["summary"],
                        "evidence": [],
                        "evidence_count": 0,
                        "evidence_ids": set(),
                        "matched_patterns": set(),
                        "role_counts": {},
                        "source_ids": set(),
                        "source_kinds": set(),
                    },
                )
                group["matched_patterns"].update(hit["patterns"])
                evidence = _evidence_item(
                    info=info,
                    record_id=record_id,
                    role=role,
                    matched_patterns=hit["patterns"],
                    block=block,
                    home=home,
                    show_evidence=show_evidence,
                )
                if evidence["evidence_id"] in group["evidence_ids"]:
                    continue
                group["evidence_ids"].add(evidence["evidence_id"])
                group["evidence_count"] += 1
                group["source_ids"].add(info.source_id)
                group["source_kinds"].add(info.source_kind)
                group["role_counts"][role] = (
                    int(group["role_counts"].get(role, 0)) + 1
                )
                if len(group["evidence"]) < limit:
                    group["evidence"].append(evidence)
    candidates = []
    for category in sorted(grouped):
        group = grouped[category]
        candidates.append(
            {
                "id": _stable_id([category, group["summary"]]),
                "category": category,
                "entity": group["entity"],
                "severity": group["severity"],
                "summary": group["summary"],
                "evidence": group["evidence"],
                "evidence_count": group["evidence_count"],
                "source_count": len(group["source_ids"]),
                "source_ids": sorted(group["source_ids"]),
                "source_kinds": sorted(group["source_kinds"]),
                "role_counts": dict(sorted(group["role_counts"].items())),
                "matched_patterns": sorted(group["matched_patterns"]),
                "score": group["evidence_count"] * 10 + len(group["matched_patterns"]),
            }
        )
    candidates.sort(key=lambda item: (-int(item["score"]), str(item["category"])))
    return {
        "schema": "legion.session-learning.scan.v2",
        "generated_at": _utc_now().isoformat().replace("+00:00", "Z"),
        "home_id": _stable_id(["home", str(home)]),
        "lookback_days": days,
        "query_count": len(queries),
        "query_ids": [_stable_id(["query", query]) for query in queries],
        "queries": queries if show_evidence else [],
        "scope": {
            "repo_id": scope.repo_id if scope else "",
            "repo_scoped": scope is not None,
            "harnesses": sorted(harnesses),
            "roles": sorted(roles),
            "source_kinds": sorted(source_kinds),
            "session_limit": session_limit,
            "include_benchmarks": include_benchmarks,
            "include_subagents": include_subagents,
            "include_tool_results": include_tool_results,
            "show_evidence": show_evidence,
        },
        "files_discovered": len(files),
        "files_scanned": len(sources),
        "files_skipped": skipped,
        "files_limited": limited,
        "files_filtered": filter_counts,
        "records_scanned": records_scanned,
        "records_filtered_by_role": records_filtered_by_role,
        "records_deduplicated": records_deduplicated,
        "max_file_mb": max_file_mb,
        "candidates": candidates,
    }


def _outcomes_path(log_root: str) -> Path:
    return Path(log_root).expanduser() / "self-learn" / "outcomes.jsonl"


def _outcome(candidate: dict[str, Any]) -> dict[str, Any]:
    target_type, target_name = str(candidate["entity"]).split(":", 1)
    descriptors: list[str] = []
    evidence_ids: list[str] = []
    for item in candidate.get("evidence", []):
        evidence_id = str(
            item.get("evidence_id")
            or _stable_id(
                [
                    "legacy-evidence",
                    item.get("source_path", ""),
                    item.get("role", ""),
                    item.get("snippet", ""),
                ]
            )
        )
        evidence_ids.append(evidence_id)
        descriptors.append(
            f"{evidence_id} ({item.get('source_kind', 'legacy-source')}, "
            f"{item.get('role', 'unknown')})"
        )
    evidence_count = int(candidate.get("evidence_count") or len(evidence_ids))
    evidence = (
        f"{evidence_count} deduplicated evidence record(s)"
        + (f"; sampled ids: {', '.join(descriptors)}" if descriptors else "")
    )
    return {
        "schema": OUTCOME_SCHEMA,
        "id": _stable_id(["session-learn", candidate["category"], candidate["summary"]]),
        "ts": _utc_now().isoformat().replace("+00:00", "Z"),
        "source": "session-learn",
        "target_type": target_type,
        "target_name": target_name,
        "severity": candidate["severity"],
        "summary": _short(str(candidate["summary"]), 500),
        "evidence": _short(evidence, 1200),
        "run_id": "",
        "source_path": "",
        "metadata": {
            "category": candidate["category"],
            "evidence_count": evidence_count,
            "evidence_ids": evidence_ids,
            "matched_patterns": candidate.get("matched_patterns", []),
            "role_counts": candidate.get("role_counts", {}),
            "source_ids": candidate.get("source_ids", []),
            "source_kinds": candidate.get("source_kinds", []),
        },
    }


def record_candidates(candidates: list[dict[str, Any]], log_root: str) -> list[dict[str, Any]]:
    outcomes = [_outcome(candidate) for candidate in candidates]
    path = _outcomes_path(log_root)
    path.parent.mkdir(parents=True, exist_ok=True)
    existing: set[str] = set()
    try:
        with path.open(encoding="utf-8") as handle:
            for line in handle:
                try:
                    payload = json.loads(line)
                except ValueError:
                    continue
                if isinstance(payload, dict) and payload.get("id"):
                    existing.add(str(payload["id"]))
    except OSError:
        pass
    new_outcomes = [
        outcome for outcome in outcomes if str(outcome.get("id")) not in existing
    ]
    with path.open("a", encoding="utf-8") as handle:
        for outcome in new_outcomes:
            handle.write(json.dumps(outcome, sort_keys=True, ensure_ascii=False))
            handle.write("\n")
    return new_outcomes


def render(payload: dict[str, Any]) -> str:
    lines = [
        f"session-learn: {len(payload['candidates'])} candidate(s), "
        f"{payload['files_scanned']} of {payload.get('files_discovered', payload['files_scanned'])} "
        f"sources scanned, {payload.get('records_deduplicated', 0)} duplicate record(s) removed"
    ]
    for candidate in payload["candidates"]:
        lines.append(
            f"\n{candidate['category']} -> {candidate['entity']} "
            f"[{candidate['severity']}]"
        )
        lines.append(f"- {candidate['summary']}")
        lines.append(
            f"  evidence: {candidate.get('evidence_count', len(candidate.get('evidence', [])))} "
            f"record(s) across {candidate.get('source_count', 0)} source(s)"
        )
        for evidence in candidate["evidence"][:2]:
            lines.append(
                f"  {evidence.get('evidence_id', 'legacy')} "
                f"{evidence.get('source_kind', 'source')} {evidence.get('role', 'unknown')}: "
                f"{evidence.get('summary', 'matched guardrail signals')}"
            )
            if evidence.get("snippet"):
                lines.append(f"    source: {evidence.get('source_path', 'hidden')}")
                lines.append(f"    {evidence['snippet']}")
    return "\n".join(lines)


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(
        prog="legion-session-learn",
        description=(
            "Mine bounded, provenance-aware agent sessions into privacy-safe "
            "self-learning candidates."
        ),
    )
    parser.add_argument(
        "--home", default="~", help="home directory containing agent logs"
    )
    parser.add_argument(
        "--logs", default=DEFAULT_LOG_ROOT, help="Legion log root for --record"
    )
    parser.add_argument(
        "--repo",
        help=(
            "scope sources to this repository using cwd/git metadata; sources without "
            "matching provenance are excluded"
        ),
    )
    parser.add_argument("--lookback-days", type=int, default=3)
    parser.add_argument(
        "--query",
        action="append",
        default=[],
        help="filter eligible user/assistant records by text (repeatable)",
    )
    parser.add_argument(
        "--harness",
        action="append",
        choices=sorted(VALID_HARNESSES),
        default=[],
        help="include only this harness (repeatable)",
    )
    parser.add_argument(
        "--role",
        action="append",
        choices=sorted(VALID_ROLES),
        default=[],
        help="include only this role (default: user, assistant, unknown; repeatable)",
    )
    parser.add_argument(
        "--source-kind",
        action="append",
        choices=sorted(VALID_SOURCE_KINDS),
        default=[],
        help="include only this source kind (repeatable)",
    )
    parser.add_argument(
        "--session-limit",
        type=int,
        default=DEFAULT_SESSION_LIMIT,
        help=f"newest eligible source files to scan (default: {DEFAULT_SESSION_LIMIT}; 0 = unlimited)",
    )
    parser.add_argument(
        "--limit",
        type=int,
        default=5,
        help="hashed evidence samples retained per category",
    )
    parser.add_argument(
        "--max-file-mb",
        type=float,
        default=8.0,
        help="skip larger non-JSONL files; session JSONL is streamed regardless of size",
    )
    parser.add_argument(
        "--include-subagents",
        action="store_true",
        help="include sidechain/collaboration subagent sessions",
    )
    parser.add_argument(
        "--include-benchmarks",
        action="store_true",
        help="include sources marked as benchmark/eval/test fixtures",
    )
    parser.add_argument(
        "--include-tool-results",
        action="store_true",
        help="include tool-result content (excluded by default)",
    )
    parser.add_argument(
        "--show-evidence",
        action="store_true",
        help=(
            "include best-effort-redacted snippets and home-relative paths for "
            "local inspection; inspect before sharing"
        ),
    )
    parser.add_argument(
        "--record",
        action="store_true",
        help="append candidates as self-learning outcomes",
    )
    parser.add_argument("--json", action="store_true")
    args = parser.parse_args(argv)
    repo_path = Path(args.repo).expanduser().resolve() if args.repo else None
    if repo_path is not None and not repo_path.is_dir():
        parser.error(f"--repo is not a directory: {repo_path}")
    if not args.logs:
        state_repo = repo_path if repo_path is not None else Path.cwd()
        args.logs = legion_state.resolve_state(str(state_repo))["state_root"]

    payload = scan(
        Path(args.home).expanduser(),
        days=max(0, args.lookback_days),
        queries=list(args.query or []),
        limit=max(1, args.limit),
        max_file_mb=max(0.0, args.max_file_mb),
        repo=repo_path,
        harnesses=set(args.harness or []),
        roles=set(args.role or []) or set(DEFAULT_ROLES),
        source_kinds=set(args.source_kind or []),
        session_limit=max(0, args.session_limit),
        include_subagents=args.include_subagents,
        include_benchmarks=args.include_benchmarks,
        include_tool_results=args.include_tool_results,
        show_evidence=args.show_evidence,
    )
    if args.record:
        payload["recorded"] = record_candidates(payload["candidates"], args.logs)
        outcomes_path = _outcomes_path(args.logs)
        payload["outcomes_id"] = _stable_id(["outcomes", str(outcomes_path)])
        payload["outcomes_path"] = str(outcomes_path) if args.show_evidence else ""
    if args.json:
        print(json.dumps(payload, indent=2, sort_keys=True))
    else:
        print(render(payload))
        if args.record:
            suffix = (
                f" -> {payload['outcomes_path']}" if payload["outcomes_path"] else ""
            )
            print(f"\nrecorded: {len(payload['recorded'])}{suffix}")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
