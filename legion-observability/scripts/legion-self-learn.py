#!/usr/bin/env python3
"""Legion self-learning loop for harness entities.

This is intentionally local-first and validation-first:

1. Mine outcomes from durable Legion spans, review verdict artifacts, manual bug
   records, trigger evals, and routing optimizer advice.
2. Attach each outcome to a catalog entity (plugin, skill, command, agent, hook,
   MCP) instead of only to a model route.
3. Write a durable memory/proposal queue every day. This is the safe default the
   daily cron uses.
4. Leave source proposals for the separate review-only ``legion-improve``
   engine; this command only mines and records learning evidence.

The shape is inspired by harness-bench and autoresearch style loops: establish a
baseline, record evidence, and hand bounded proposals to a separately reviewed
improvement engine. Legion already has traces, catalog, trigger eval, and routing
optimizer; this script connects those pieces.
"""

from __future__ import annotations

import argparse
import glob
import hashlib
import importlib.util
import json
import math
import os
import re
import subprocess
import sys
import time
import unicodedata
from collections import defaultdict
from datetime import datetime, timezone
from typing import Any

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import legion_state  # noqa: E402
import legion_learning_context  # noqa: E402
import legion_file_lock  # noqa: E402

SPAN_SCHEMA = "legion.span.v1"
OUTCOME_SCHEMA = "legion.outcome.v1"
MEMORY_SCHEMA = "legion.self-learning.memory.v1"
# v2 makes the unmeasured state explicit: ``measurement`` is present and
# ``score`` may be null. Emitting that under v1 would silently break consumers
# that correctly treated the original v1 score as numeric.
SCORECARD_SCHEMA = "legion.self-learning.scorecard.v2"
IMPROVEMENT_PROPOSAL_SCHEMA = "legion.improvement-proposal.v1"
DEFAULT_LOG_ROOT = ""
SUCCESS_STATUSES = {"ok"}
SEVERITY_ORDER = {"info": 0, "low": 1, "medium": 2, "high": 3, "critical": 4}
INPUT_CURSOR_SCHEMA = "legion.self-learning.input-cursor.v1"
SPAN_CURSOR_SCHEMA = "legion.self-learning.span-input-cursor.v2"
REPOSITORY_IDENTITY_CACHE_SCHEMA = "legion.repository-identity-cache.v1"
REPOSITORY_IDENTITY_CACHE_FILE = ".repository-identities.v1.json"
CURSOR_TAIL_BYTES = 4096
MAX_REPOSITORY_GIT_PROBES = 64
MAX_SPAN_TEXT_LENGTH = 4096
MAX_SPAN_IDENTIFIER_LENGTH = 512
MAX_SPAN_COLLECTION_ITEMS = 128
MAX_SPAN_NESTING = 8
SPAN_IDENTITY_VERSION = 2
SPAN_STATUSES = {"ok", "failed", "error", "over_budget", "blocked"}
GLOBAL_HINT_RESERVE = 100
PROJECT_HINT_CAP = (
    legion_learning_context.MAX_HINTS
    + legion_learning_context.MAX_EXCLUDED_HINTS
    - GLOBAL_HINT_RESERVE
)
STOPWORDS = {
    "the", "a", "an", "and", "or", "of", "to", "for", "in", "on", "with", "is",
    "are", "be", "this", "that", "it", "as", "at", "by", "from", "into", "via",
    "use", "used", "using", "when", "how", "do", "i", "my", "you", "your", "we",
    "can", "should", "need", "want", "please", "help", "me", "across", "so",
    "also", "etc", "covers", "includes", "plus", "per", "any", "task", "run",
    "review", "fix", "bug", "feature", "code", "files", "repo",
}


def _here() -> str:
    return os.path.dirname(os.path.abspath(__file__))


def _find_marketplace_root(start: str) -> str:
    # Return the OUTERMOST marketplace.json, not the first one going up. When
    # legion-core is vendored (consumer/vendored/legion-core/...), the nearest
    # match is legion-core's OWN marketplace.json; the consumer's sits at the
    # repo root above it. Standalone legion-core has a single match (its root).
    current = os.path.abspath(start)
    match = ""
    while current and current != os.path.dirname(current):
        candidate = os.path.join(current, ".claude-plugin", "marketplace.json")
        if os.path.exists(candidate):
            match = current
        current = os.path.dirname(current)
    return match


def _git_marketplace_root(start: str) -> str:
    """Return the active worktree root when it owns a Legion marketplace."""
    try:
        result = subprocess.run(
            ["git", "-C", start, "rev-parse", "--show-toplevel"],
            check=False,
            capture_output=True,
            text=True,
        )
    except OSError:
        return ""
    root = result.stdout.strip() if result.returncode == 0 else ""
    marketplace = os.path.join(root, ".claude-plugin", "marketplace.json")
    return os.path.abspath(root) if root and os.path.isfile(marketplace) else ""


def default_repo() -> str:
    # Prefer an explicit override, then the active Git worktree (important when
    # a Legion worktree itself is nested under another marketplace checkout),
    # then the outermost non-Git consumer marketplace.
    env = (
        os.environ.get("MARKETPLACE_ROOT")
        or os.environ.get("LEGION_ROOT")
        or os.environ.get("LEGION_MARKETPLACE_ROOT")
    )
    if env:
        return os.path.abspath(os.path.expanduser(env))
    worktree = _git_marketplace_root(_here())
    if worktree:
        return worktree
    walked = _find_marketplace_root(_here())
    if walked:
        return walked
    return os.path.abspath(os.path.join(_here(), "..", ".."))


def _load_module(name: str, path: str):
    spec = importlib.util.spec_from_file_location(name, path)
    if spec is None or spec.loader is None:
        raise RuntimeError(f"could not import {path}")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def _catalog_module():
    return _load_module("legion_catalog", os.path.join(_here(), "legion-catalog.py"))


def _eval_module():
    return _load_module("legion_eval", os.path.join(_here(), "legion-eval.py"))


def _optimize_module(repo: str):
    return _load_module(
        "legion_optimize",
        os.path.join(repo, "legion-router", "scripts", "legion-optimize.py"),
    )


def _iso_utc() -> str:
    return datetime.now(timezone.utc).isoformat().replace("+00:00", "Z")


def _date_utc() -> str:
    return datetime.now(timezone.utc).strftime("%Y-%m-%d")


def _text(value: Any) -> str:
    return value.strip() if isinstance(value, str) else ""


def _dict(value: Any) -> dict[str, Any]:
    return value if isinstance(value, dict) else {}


def _list(value: Any) -> list[Any]:
    return value if isinstance(value, list) else []


def _severity(value: Any, default: str = "medium") -> str:
    text = _text(value).lower()
    if text in SEVERITY_ORDER:
        return text
    if text in {"blocker", "severe"}:
        return "critical"
    if text in {"warn", "warning"}:
        return "medium"
    return default


def _tokenize(text: str) -> set[str]:
    toks = re.split(r"[^a-z0-9]+", (text or "").lower())
    return {tok for tok in toks if len(tok) > 1 and tok not in STOPWORDS}


def _stable_id(parts: list[Any]) -> str:
    raw = json.dumps(parts, sort_keys=True, ensure_ascii=True, default=str)
    return hashlib.sha256(raw.encode("utf-8")).hexdigest()[:16]


def _short(text: str, limit: int = 240) -> str:
    collapsed = " ".join(_text(text).split())
    if len(collapsed) <= limit:
        return collapsed
    return collapsed[: limit - 3].rstrip() + "..."


def _ensure_dir(path: str) -> None:
    os.makedirs(path, exist_ok=True)


def self_learn_dir(log_root: str) -> str:
    return os.path.join(os.path.expanduser(log_root), "self-learn")


def memory_path(log_root: str) -> str:
    return os.path.join(self_learn_dir(log_root), "harness-memory.json")


def experiments_path(log_root: str) -> str:
    return os.path.join(self_learn_dir(log_root), "experiments.md")


def experiment_ledger_path(log_root: str) -> str:
    return os.path.join(self_learn_dir(log_root), "experiments.tsv")


def outcomes_path(log_root: str) -> str:
    return os.path.join(self_learn_dir(log_root), "outcomes.jsonl")


def improvement_queue_dir(log_root: str) -> str:
    return os.path.join(self_learn_dir(log_root), "improvement-queue")


def daily_report_path(log_root: str, day: str | None = None) -> str:
    return os.path.join(self_learn_dir(log_root), "reports", f"{day or _date_utc()}.json")


def _json_file(path: str) -> Any:
    try:
        with open(path, encoding="utf-8") as handle:
            return json.load(handle)
    except (OSError, RecursionError, ValueError, TypeError):
        return None


def _write_json(path: str, payload: Any) -> None:
    legion_learning_context.atomic_write_json(path, payload)


def _append_jsonl(path: str, payload: dict[str, Any]) -> None:
    _ensure_dir(os.path.dirname(path))
    with open(path, "a", encoding="utf-8") as handle:
        handle.write(json.dumps(payload, sort_keys=True, ensure_ascii=False))
        handle.write("\n")


def _spans_dir(log_root: str, telemetry_dir: str = "") -> str:
    if telemetry_dir:
        path = telemetry_dir
    elif log_root:
        path = os.path.join(log_root, "spans")
    else:
        path = os.environ.get("LEGION_TELEMETRY_DIR") or "spans"
    return os.path.abspath(os.path.expanduser(path))


def _canonical_path(path: str) -> str:
    try:
        return os.path.realpath(os.path.abspath(os.path.expanduser(path)))
    except (OSError, TypeError, ValueError):
        return ""


def _stat_fingerprint(path: str) -> dict[str, Any]:
    """Return cheap cache invalidation metadata without following Git."""
    try:
        stat = os.stat(path)
    except (OSError, TypeError, ValueError):
        return {"missing": True}
    return {
        "device": int(stat.st_dev),
        "inode": int(stat.st_ino),
        "mode": int(stat.st_mode),
        "size": int(stat.st_size),
        "mtime_ns": int(stat.st_mtime_ns),
        "ctime_ns": int(stat.st_ctime_ns),
    }


def _git_config_paths(repo_root: str) -> list[str]:
    """Find config files whose changes can stale a cached remote identity."""
    git_marker = os.path.join(repo_root, ".git")
    try:
        if os.path.isdir(git_marker):
            return [
                os.path.join(git_marker, "config"),
                os.path.join(git_marker, "config.worktree"),
            ]
        if not os.path.isfile(git_marker):
            return []
        with open(git_marker, encoding="utf-8") as handle:
            line = handle.readline(8192).strip()
        if not line.lower().startswith("gitdir:"):
            return []
        git_dir = line.split(":", 1)[1].strip()
        if not os.path.isabs(git_dir):
            git_dir = os.path.join(repo_root, git_dir)
        git_dir = os.path.normpath(git_dir)
        common_dir = git_dir
        common_file = os.path.join(git_dir, "commondir")
        try:
            with open(common_file, encoding="utf-8") as handle:
                common_value = handle.readline(8192).strip()
            if common_value:
                common_dir = (
                    common_value
                    if os.path.isabs(common_value)
                    else os.path.normpath(os.path.join(git_dir, common_value))
                )
        except (OSError, UnicodeError):
            pass
        return [
            os.path.join(common_dir, "config"),
            os.path.join(git_dir, "config.worktree"),
        ]
    except (OSError, UnicodeError, TypeError, ValueError):
        return []


def _repository_cache_fingerprint(repo_root: str) -> dict[str, Any]:
    """Fingerprint identity inputs cheaply enough to check every cached store."""
    paths = [repo_root, os.path.join(repo_root, ".git"), *_git_config_paths(repo_root)]
    return {
        path: _stat_fingerprint(path)
        for path in sorted(set(paths))
    }


def _recorded_repo_roots(project_dir: str) -> list[str] | None:
    """Read the canonical checkout records for one project store, best-effort."""
    roots: set[str] = set()
    try:
        with open(os.path.join(project_dir, "repos.jsonl"), encoding="utf-8") as handle:
            for line in handle:
                try:
                    root = _text(json.loads(line).get("repo_root"))
                except (
                    AttributeError,
                    json.JSONDecodeError,
                    RecursionError,
                    TypeError,
                ):
                    continue
                if root:
                    roots.add(os.path.abspath(os.path.expanduser(root)))
    except (OSError, UnicodeError, TypeError, ValueError):
        return None
    return sorted(roots)


def _filesystem_repository_identity(repo_root: str) -> str:
    """Resolve the common Git identity without starting a subprocess.

    Normal checkouts record ``remote.origin.url`` in their common config. Git
    includes and malformed/unreadable layouts are deliberately left to the
    bounded Git fallback because reproducing Git's complete config precedence
    here would create a second, less reliable parser.
    """
    root = os.path.abspath(os.path.expanduser(repo_root))
    if not os.path.isdir(root):
        return ""
    git_marker = os.path.join(root, ".git")
    if not os.path.lexists(git_marker):
        return root
    config_paths = _git_config_paths(root)
    if not config_paths:
        return ""
    origin = ""
    uncertain = False
    for path in config_paths:
        try:
            with open(path, encoding="utf-8") as handle:
                section = ""
                read_chars = 0
                for raw in handle:
                    read_chars += len(raw)
                    if read_chars > 1_048_576:
                        return ""
                    line = raw.strip()
                    if not line or line.startswith(("#", ";")):
                        continue
                    if line.startswith("[") and line.endswith("]"):
                        section = " ".join(line[1:-1].lower().split())
                        if section.startswith("include"):
                            uncertain = True
                        continue
                    if section != 'remote "origin"':
                        continue
                    match = re.match(r"url\s*=\s*(.*)$", line, flags=re.IGNORECASE)
                    if not match:
                        continue
                    value = match.group(1).strip()
                    if (
                        len(value) >= 2
                        and value[0] == value[-1]
                        and value[0] in {'"', "'"}
                    ):
                        value = value[1:-1]
                    origin = value
        except FileNotFoundError:
            continue
        except (OSError, UnicodeError, ValueError):
            return ""
    if origin and not uncertain:
        try:
            return _text(legion_state._normalize_remote(origin))
        except (AttributeError, TypeError, ValueError):
            return ""
    # Absence and include precedence are harder to prove from a partial parser;
    # leave those cases to the bounded Git path instead of guessing an identity.
    return ""


def _repository_entry(
    repo_root: str, identity: str | None = None
) -> dict[str, Any] | None:
    repo_root = os.path.abspath(os.path.expanduser(repo_root))
    if not os.path.isdir(repo_root):
        return None
    used_git_fallback = identity is None
    try:
        if identity is None:
            identity = legion_state.repository_identity(repo_root)
        project = legion_state.repository_project_id(repo_root, identity)
    except Exception:
        return None
    if not _text(identity) or not _text(project):
        return None
    # ``repository_identity`` deliberately falls back to the absolute path on
    # Git failures. Do not make a transient timeout permanent in this cache; a
    # Git checkout with a path fallback is retried on the next daily scan.
    if (
        used_git_fallback
        and _canonical_path(identity) == _canonical_path(repo_root)
        and os.path.lexists(os.path.join(repo_root, ".git"))
    ):
        return None
    return {
        "repo_root": repo_root,
        "repository_identity": identity,
        "repository_project_id": project,
        "identity_fingerprint": _repository_cache_fingerprint(repo_root),
    }


def _identity_scan_diagnostics() -> dict[str, Any]:
    return {
        "identity_unique_roots": 0,
        "identity_filesystem_resolutions": 0,
        "identity_git_probes": 0,
        "identity_probe_limit": MAX_REPOSITORY_GIT_PROBES,
        "identity_probe_capped": False,
        "identity_probe_skipped_roots": 0,
    }


def _cached_repository_stores(
    projects_root: str,
    diagnostics: dict[str, Any] | None = None,
) -> list[dict[str, Any]]:
    """Resolve store identities with one non-authoritative, atomic cache.

    ``repos.jsonl`` and the relevant Git config metadata invalidate individual
    entries. A missing, malformed, unwritable, or stale cache merely makes this
    scan slower; it never decides correctness on its own.
    """
    scan = _identity_scan_diagnostics()
    resolved_roots: dict[str, dict[str, Any] | None] = {}
    skipped_roots: set[str] = set()

    def finish() -> None:
        scan["identity_unique_roots"] = len(resolved_roots)
        scan["identity_probe_skipped_roots"] = len(skipped_roots)
        if diagnostics is not None:
            diagnostics.clear()
            diagnostics.update(scan)

    def resolve_root(repo_root: str) -> dict[str, Any] | None:
        canonical = _canonical_path(repo_root)
        if not canonical:
            return None
        if canonical in resolved_roots:
            return resolved_roots[canonical]
        if not os.path.isdir(repo_root):
            resolved_roots[canonical] = None
            return None
        identity = _filesystem_repository_identity(repo_root)
        if identity:
            scan["identity_filesystem_resolutions"] += 1
            entry = _repository_entry(repo_root, identity)
        elif scan["identity_git_probes"] < MAX_REPOSITORY_GIT_PROBES:
            scan["identity_git_probes"] += 1
            entry = _repository_entry(repo_root)
        else:
            scan["identity_probe_capped"] = True
            skipped_roots.add(canonical)
            entry = None
        resolved_roots[canonical] = entry
        return entry

    cache_path = os.path.join(projects_root, REPOSITORY_IDENTITY_CACHE_FILE)
    cached_payload = _dict(_json_file(cache_path))
    cached_stores = (
        _dict(cached_payload.get("stores"))
        if cached_payload.get("schema") == REPOSITORY_IDENTITY_CACHE_SCHEMA
        else {}
    )
    try:
        with os.scandir(projects_root) as iterator:
            directories = sorted(iterator, key=lambda entry: entry.name)
    except OSError:
        finish()
        return []

    stores: list[dict[str, Any]] = []
    next_cache: dict[str, Any] = {}
    for directory in directories:
        try:
            if not directory.is_dir(follow_symlinks=False):
                continue
            project_dir = os.path.abspath(directory.path)
            repos_path = os.path.join(project_dir, "repos.jsonl")
            repos_fingerprint = _stat_fingerprint(repos_path)
            if repos_fingerprint.get("missing"):
                continue
            cached = _dict(cached_stores.get(directory.name))
            cached_repositories = cached.get("repositories")
            repositories: list[dict[str, Any]] = []
            cache_valid = (
                cached.get("complete") is True
                and cached.get("repos_fingerprint") == repos_fingerprint
                and isinstance(cached_repositories, list)
            )
            if cache_valid:
                for raw in cached_repositories:
                    cached_entry = _dict(raw)
                    root = _text(cached_entry.get("repo_root"))
                    fingerprint = _repository_cache_fingerprint(root) if root else {}
                    entry = resolve_root(root) if root else None
                    if (
                        not root
                        or not os.path.isdir(root)
                        or cached_entry.get("identity_fingerprint") != fingerprint
                        or entry is None
                        or _text(entry.get("repository_identity"))
                        != _text(cached_entry.get("repository_identity"))
                        or _text(entry.get("repository_project_id"))
                        != _text(cached_entry.get("repository_project_id"))
                    ):
                        cache_valid = False
                        break
                    repositories.append(entry)
            if not cache_valid:
                repositories = []
                roots = _recorded_repo_roots(project_dir)
                cache_valid = roots is not None
                for root in roots or []:
                    entry = resolve_root(root)
                    if entry is None:
                        cache_valid = False
                    else:
                        repositories.append(entry)
            repositories.sort(
                key=lambda item: (
                    _text(item.get("repository_project_id")),
                    _text(item.get("repository_identity")),
                    _text(item.get("repo_root")),
                )
            )
            if cache_valid:
                next_cache[directory.name] = {
                    "complete": True,
                    "repos_fingerprint": repos_fingerprint,
                    "repositories": repositories,
                }
            stores.append(
                {
                    "project_id": directory.name,
                    "state_root": project_dir,
                    "repositories": repositories,
                }
            )
        except Exception:
            continue

    next_payload = {
        "schema": REPOSITORY_IDENTITY_CACHE_SCHEMA,
        "stores": dict(sorted(next_cache.items())),
    }
    if next_payload != cached_payload:
        try:
            _write_json(cache_path, next_payload)
        except Exception:
            pass
    finish()
    return stores


def _local_span_source(log_root: str, telemetry_dir: str) -> dict[str, Any]:
    state_root = os.path.abspath(os.path.expanduser(log_root)) if log_root else ""
    return {
        "project_id": os.path.basename(state_root.rstrip(os.sep)) or "explicit",
        "state_root": state_root,
        "telemetry_dir": _spans_dir(log_root, telemetry_dir),
        "current": True,
    }


def _span_sources(
    log_root: str,
    telemetry_dir: str,
    *,
    repo: str = "",
    state: dict[str, str] | None = None,
) -> tuple[list[dict[str, Any]], bool, dict[str, Any]]:
    """Return checkout-local span stores sharing the target repository identity."""
    local = _local_span_source(log_root, telemetry_dir)
    discovery = _identity_scan_diagnostics()
    if not repo:
        return [local], False, discovery
    try:
        resolved = state or legion_state.resolve_state(repo)
        state_root = os.path.abspath(os.path.expanduser(resolved["state_root"]))
        expected_telemetry = os.path.join(state_root, "spans")
        requested_telemetry = _spans_dir(log_root, telemetry_dir)
        # Env/config roots are deliberately isolated. An explicitly exported
        # telemetry directory also pins even when it happens to equal the auto
        # default byte-for-byte.
        if (
            resolved.get("source") != "auto"
            or os.environ.get("LEGION_STATE_ROOT")
            or os.environ.get("LEGION_TELEMETRY_DIR")
            or _canonical_path(log_root) != _canonical_path(state_root)
            or _canonical_path(requested_telemetry)
            != _canonical_path(expected_telemetry)
        ):
            return [local], False, discovery
        target_identity = _text(resolved.get("repository_identity"))
        target_project = _text(resolved.get("repository_project_id"))
        if not target_identity or not target_project:
            return [local], False, discovery
        projects_root = os.path.dirname(state_root)
        sources: list[dict[str, Any]] = []
        for store in _cached_repository_stores(projects_root, discovery):
            repositories = _list(store.get("repositories"))
            verified_roots = sorted(
                _text(_dict(item).get("repo_root"))
                for item in repositories
                if _text(_dict(item).get("repository_identity")) == target_identity
                and _text(_dict(item).get("repository_project_id"))
                == target_project
            )
            if not verified_roots:
                continue
            store_root = _text(store.get("state_root"))
            sources.append(
                {
                    "project_id": _text(store.get("project_id")),
                    "state_root": store_root,
                    "telemetry_dir": os.path.join(store_root, "spans"),
                    "current": _canonical_path(store_root)
                    == _canonical_path(state_root),
                    "verified_repo_roots": verified_roots,
                }
            )
        if not any(source.get("current") for source in sources):
            sources.append(
                {
                    "project_id": _text(resolved.get("project_id"))
                    or os.path.basename(state_root),
                    "state_root": state_root,
                    "telemetry_dir": expected_telemetry,
                    "current": True,
                }
            )
        unique: dict[str, dict[str, Any]] = {}
        for source in sources:
            key = _canonical_path(_text(source.get("telemetry_dir")))
            if key:
                previous = unique.get(key)
                if previous is None or source.get("current"):
                    unique[key] = source
        return (
            sorted(unique.values(), key=lambda item: _text(item.get("state_root"))),
            True,
            discovery,
        )
    except Exception:
        return [local], False, discovery


def _span_paths(telemetry_dir: str, day: str | None = None) -> list[str]:
    if day:
        return [os.path.join(telemetry_dir, f"{day}.jsonl")]
    try:
        return sorted(glob.glob(os.path.join(telemetry_dir, "*.jsonl")))
    except (OSError, TypeError, ValueError):
        return []


def _read_span_paths(paths: list[str]) -> list[dict[str, Any]]:
    spans: list[dict[str, Any]] = []
    for path in paths:
        try:
            with open(path, encoding="utf-8") as handle:
                for line in handle:
                    text = line.strip()
                    if not text:
                        continue
                    try:
                        payload = json.loads(text)
                    except (RecursionError, ValueError, TypeError):
                        continue
                    if isinstance(payload, dict) and payload.get("schema") == SPAN_SCHEMA:
                        spans.append(payload)
        except (OSError, UnicodeError, TypeError, ValueError):
            continue
    return spans


_INVALID_SPAN_VALUE = object()


def _bounded_span_value(value: Any, depth: int = 0) -> Any:
    """Bound attacker-controlled JSON retained in learning reports and hashes."""
    if isinstance(value, str):
        return value[:MAX_SPAN_TEXT_LENGTH]
    if value is None or isinstance(value, (bool, int)):
        return value
    if isinstance(value, float):
        return value if math.isfinite(value) else _INVALID_SPAN_VALUE
    if isinstance(value, dict):
        if depth >= MAX_SPAN_NESTING:
            return {}
        bounded: dict[str, Any] = {}
        for index, (raw_key, raw_value) in enumerate(value.items()):
            if index >= MAX_SPAN_COLLECTION_ITEMS or not isinstance(raw_key, str):
                break
            child = _bounded_span_value(raw_value, depth + 1)
            if child is _INVALID_SPAN_VALUE:
                return _INVALID_SPAN_VALUE
            bounded[raw_key[:MAX_SPAN_IDENTIFIER_LENGTH]] = child
        return bounded
    if isinstance(value, list):
        if depth >= MAX_SPAN_NESTING:
            return []
        bounded_items: list[Any] = []
        for raw_item in value[:MAX_SPAN_COLLECTION_ITEMS]:
            child = _bounded_span_value(raw_item, depth + 1)
            if child is _INVALID_SPAN_VALUE:
                return _INVALID_SPAN_VALUE
            bounded_items.append(child)
        return bounded_items
    return _INVALID_SPAN_VALUE


def _validated_span(payload: Any) -> dict[str, Any] | None:
    """Validate and bound the in-repository ``legion.span.v1`` contract."""
    if not isinstance(payload, dict) or payload.get("schema") != SPAN_SCHEMA:
        return None
    required_strings = ("schema", "ts", "run_id", "executor", "model", "status")
    if any(not isinstance(payload.get(field), str) for field in required_strings):
        return None
    if payload.get("status") not in SPAN_STATUSES:
        return None
    for field in ("task",):
        if field in payload and not isinstance(payload.get(field), str):
            return None
    for field in ("trace_id", "parent_id", "archetype", "target_type", "target_name"):
        if field in payload and payload.get(field) is not None and not isinstance(
            payload.get(field), str
        ):
            return None
    for field in ("duration_ms", "cost_usd"):
        if field not in payload:
            continue
        value = payload.get(field)
        if (
            isinstance(value, bool)
            or not isinstance(value, (int, float))
            or not math.isfinite(float(value))
            or value < 0
        ):
            return None
    for field in ("tokens", "artifacts"):
        if field in payload and not isinstance(payload.get(field), dict):
            return None
    bounded = _bounded_span_value(payload)
    if not isinstance(bounded, dict):
        return None
    for field in (
        "ts",
        "run_id",
        "executor",
        "model",
        "status",
        "trace_id",
        "parent_id",
        "archetype",
        "target_type",
        "target_name",
    ):
        if isinstance(bounded.get(field), str):
            bounded[field] = bounded[field][:MAX_SPAN_IDENTIFIER_LENGTH]
    return bounded


def _normalized_span_timestamp(value: Any) -> str:
    text = _text(value)
    if not text:
        return ""
    try:
        parsed = datetime.fromisoformat(
            text[:-1] + "+00:00" if text.endswith("Z") else text
        )
    except (OverflowError, TypeError, ValueError):
        return text
    if parsed.tzinfo is None:
        return text
    return parsed.astimezone(timezone.utc).isoformat().replace("+00:00", "Z")


def _span_identity_digest(span: dict[str, Any]) -> str:
    """Hash the complete normalized payload so distinct outcomes survive."""
    normalized = dict(span)
    normalized["ts"] = _normalized_span_timestamp(span.get("ts"))
    raw = json.dumps(
        normalized, sort_keys=True, separators=(",", ":"), ensure_ascii=True
    )
    return hashlib.sha256(raw.encode("utf-8")).hexdigest()


def _span_sort_key(span: dict[str, Any]) -> tuple[str, str, str, str]:
    return (
        _normalized_span_timestamp(span.get("ts")),
        _text(span.get("run_id")),
        _text(span.get("executor")),
        hashlib.sha256(
            json.dumps(
                span, sort_keys=True, separators=(",", ":"), ensure_ascii=True
            ).encode("utf-8")
        ).hexdigest(),
    )


def _dedupe_span_batches(
    sources: list[dict[str, Any]],
    batches: list[list[dict[str, Any]]],
    seen: set[str] | None = None,
) -> tuple[list[dict[str, Any]], set[str], list[dict[str, int]]]:
    known = set(seen or set())
    unique_spans: list[dict[str, Any]] = []
    counts: list[dict[str, int]] = []
    for _source, batch in zip(sources, batches):
        raw_count = 0
        unique_count = 0
        for raw_span in batch:
            span = _validated_span(raw_span)
            if span is None:
                continue
            raw_count += 1
            identity = _span_identity_digest(span)
            if identity in known:
                continue
            known.add(identity)
            unique_count += 1
            unique_spans.append(span)
        counts.append({"spans": raw_count, "unique_spans": unique_count})
    unique_spans.sort(key=_span_sort_key)
    return unique_spans, known, counts


def _span_source_diagnostics(
    sources: list[dict[str, Any]],
    counts: list[dict[str, int]],
    *,
    aggregated: bool,
    discovery: dict[str, Any] | None = None,
) -> dict[str, Any]:
    stores: list[dict[str, Any]] = []
    for source, count in zip(sources, counts):
        stores.append(
            {
                "project_id": _text(source.get("project_id")),
                "state_root": _text(source.get("state_root")),
                "telemetry_dir": _text(source.get("telemetry_dir")),
                "current": bool(source.get("current")),
                "spans": int(count.get("spans") or 0),
                "unique_spans": int(count.get("unique_spans") or 0),
            }
        )
    result = {
        "mode": "repository" if aggregated else "pinned",
        "matched_stores": len(stores),
        "matched_sibling_stores": sum(not store["current"] for store in stores),
        "contributing_stores": sum(store["spans"] > 0 for store in stores),
        "contributing_sibling_stores": sum(
            store["spans"] > 0 and not store["current"] for store in stores
        ),
        "duplicates_removed": sum(store["spans"] for store in stores)
        - sum(store["unique_spans"] for store in stores),
        "stores": stores,
    }
    result.update(discovery or _identity_scan_diagnostics())
    return result


def _tail_digest(handle: Any, offset: int) -> str:
    start = max(0, offset - CURSOR_TAIL_BYTES)
    handle.seek(start)
    return hashlib.sha256(handle.read(offset - start)).hexdigest()


def _read_jsonl_since(
    path: str,
    previous: dict[str, Any] | None = None,
) -> tuple[list[dict[str, Any]], dict[str, Any]]:
    """Read complete JSONL rows after a verified append-only byte cursor.

    The hash of the bytes immediately preceding the cursor detects in-place
    rewrites. Truncation, replacement, or a changed tail resets to byte zero.
    A final partial line is deliberately left unread for the next invocation.
    """
    records: list[dict[str, Any]] = []
    canonical = _canonical_path(path)
    if not canonical:
        return records, {}
    try:
        stat = os.stat(canonical)
        handle = open(canonical, "rb")
    except (OSError, TypeError, ValueError):
        return records, {}
    with handle:
        prior = _dict(previous)
        try:
            offset = int(prior.get("offset") or 0)
            prior_device = int(prior.get("device") or -1)
            prior_inode = int(prior.get("inode") or -1)
        except (OverflowError, TypeError, ValueError):
            offset = 0
            prior_device = -1
            prior_inode = -1
        try:
            can_resume = (
                offset >= 0
                and offset <= stat.st_size
                and prior_device == int(stat.st_dev)
                and prior_inode == int(stat.st_ino)
                and _text(prior.get("tail_sha256")) == _tail_digest(handle, offset)
            )
            if not can_resume:
                offset = 0
            handle.seek(offset)
            committed = offset
            while True:
                raw = handle.readline()
                if not raw:
                    break
                if not raw.endswith(b"\n"):
                    break
                committed = handle.tell()
                try:
                    payload = json.loads(raw.decode("utf-8"))
                except (RecursionError, UnicodeDecodeError, ValueError, TypeError):
                    continue
                if isinstance(payload, dict):
                    records.append(payload)
            cursor = {
                "device": int(stat.st_dev),
                "inode": int(stat.st_ino),
                "offset": committed,
                "tail_sha256": _tail_digest(handle, committed),
                "reset": bool(prior and not can_resume),
            }
        except (OSError, OverflowError, TypeError, ValueError):
            return records, {}
    return records, cursor


def _load_jsonl_paths(
    paths: list[str],
    cursor: dict[str, Any] | None,
) -> tuple[list[dict[str, Any]], dict[str, Any]]:
    records: list[dict[str, Any]] = []
    next_files: dict[str, Any] = {}
    prior_files = _dict(_dict(cursor).get("files"))
    reset = False
    for path in paths:
        canonical = _canonical_path(path)
        if not canonical:
            continue
        batch, position = _read_jsonl_since(
            canonical, _dict(prior_files.get(canonical))
        )
        records.extend(batch)
        if position:
            reset = reset or bool(position.get("reset"))
            next_files[canonical] = position
    return records, {
        "schema": INPUT_CURSOR_SCHEMA,
        "files": next_files,
        "reset": reset,
    }


def _span_cursor_stores(cursor: dict[str, Any] | None) -> dict[str, dict[str, Any]]:
    """Normalize v2 per-store cursors and the legacy flat ``files`` shape."""
    prior = _dict(cursor)
    stores: dict[str, dict[str, Any]] = {}
    for raw_key, raw_store in _dict(prior.get("stores")).items():
        store = _dict(raw_store)
        telemetry = _text(store.get("telemetry_dir")) or str(raw_key)
        key = _canonical_path(telemetry)
        if not key:
            continue
        files = {
            canonical: _dict(position)
            for path, position in _dict(store.get("files")).items()
            if (canonical := _canonical_path(str(path)))
        }
        stores[key] = {
            "project_id": _text(store.get("project_id")),
            "state_root": _text(store.get("state_root")),
            "telemetry_dir": telemetry,
            "files": files,
        }
    # Before v2, span cursors used the generic per-file shape. Group those
    # canonical file keys by their containing telemetry directory on upgrade.
    for path, position in _dict(prior.get("files")).items():
        canonical = _canonical_path(str(path))
        if not canonical:
            continue
        key = _canonical_path(os.path.dirname(canonical))
        if not key:
            continue
        store = stores.setdefault(
            key,
            {
                "project_id": "",
                "state_root": os.path.dirname(key),
                "telemetry_dir": key,
                "files": {},
            },
        )
        _dict(store.get("files"))[canonical] = _dict(position)
    return stores


def _cursor_span_prefix(
    path: str, position: dict[str, Any]
) -> list[dict[str, Any]] | None:
    """Read identities already consumed by a legacy cursor during v2 migration."""
    spans: list[dict[str, Any]] = []
    canonical = _canonical_path(path)
    try:
        offset = int(position.get("offset") or 0)
        device = int(position.get("device") or -1)
        inode = int(position.get("inode") or -1)
        stat = os.stat(canonical)
        handle = open(canonical, "rb")
    except (OSError, OverflowError, TypeError, ValueError):
        return None
    with handle:
        try:
            if (
                offset < 0
                or offset > stat.st_size
                or device != int(stat.st_dev)
                or inode != int(stat.st_ino)
                or _text(position.get("tail_sha256")) != _tail_digest(handle, offset)
            ):
                return None
            handle.seek(0)
            while handle.tell() < offset:
                raw = handle.readline()
                if not raw or handle.tell() > offset or not raw.endswith(b"\n"):
                    break
                try:
                    payload = json.loads(raw.decode("utf-8"))
                except (RecursionError, UnicodeDecodeError, ValueError, TypeError):
                    continue
                span = _validated_span(payload)
                if span is not None:
                    spans.append(span)
        except (OSError, OverflowError, TypeError, ValueError):
            return None
    return spans


def _legacy_cursor_seen_ids(
    cursor: dict[str, Any] | None,
    stores: dict[str, dict[str, Any]],
) -> set[str] | None:
    prior = _dict(cursor)
    if "seen_span_ids" in prior:
        return {
            value
            for item in _list(prior.get("seen_span_ids"))
            if (value := _text(item))
        }
    if not prior:
        return set()
    seen: set[str] = set()
    for store in stores.values():
        for path, position in sorted(_dict(store.get("files")).items()):
            prefix = _cursor_span_prefix(path, _dict(position))
            if prefix is None:
                return None
            for span in prefix:
                seen.add(_span_identity_digest(span))
    return seen


def _flatten_span_cursor_files(stores: dict[str, dict[str, Any]]) -> dict[str, Any]:
    files: dict[str, Any] = {}
    for key in sorted(stores):
        for path, position in sorted(_dict(stores[key].get("files")).items()):
            files[path] = position
    return files


def load_spans(
    log_root: str,
    day: str | None = None,
    *,
    telemetry_dir: str = "",
    repo: str = "",
    state: dict[str, str] | None = None,
    diagnostics: dict[str, Any] | None = None,
) -> list[dict[str, Any]]:
    sources, aggregated, discovery = _span_sources(
        log_root, telemetry_dir, repo=repo, state=state
    )
    batches = [
        _read_span_paths(_span_paths(_text(source.get("telemetry_dir")), day))
        for source in sources
    ]
    spans, _seen, counts = _dedupe_span_batches(sources, batches)
    if diagnostics is not None:
        diagnostics.clear()
        diagnostics.update(
            _span_source_diagnostics(
                sources, counts, aggregated=aggregated, discovery=discovery
            )
        )
    return spans


def load_spans_incremental(
    log_root: str,
    *,
    telemetry_dir: str = "",
    cursor: dict[str, Any] | None = None,
    repo: str = "",
    state: dict[str, str] | None = None,
    diagnostics: dict[str, Any] | None = None,
) -> tuple[list[dict[str, Any]], dict[str, Any]]:
    sources, aggregated, discovery = _span_sources(
        log_root, telemetry_dir, repo=repo, state=state
    )
    prior_stores = _span_cursor_stores(cursor)
    seen_result = _legacy_cursor_seen_ids(cursor, prior_stores)
    seen = set(seen_result or set())
    prior_cursor = _dict(cursor)
    identity_reset = (
        prior_cursor.get("schema") == SPAN_CURSOR_SCHEMA
        and "seen_span_ids" in prior_cursor
        and prior_cursor.get("identity_version") != SPAN_IDENTITY_VERSION
    )
    next_stores = {
        key: {
            "project_id": _text(store.get("project_id")),
            "state_root": _text(store.get("state_root")),
            "telemetry_dir": _text(store.get("telemetry_dir")) or key,
            "files": dict(_dict(store.get("files"))),
        }
        for key, store in prior_stores.items()
    }
    batches: list[list[dict[str, Any]]] = []
    reset = seen_result is None or identity_reset
    for source in sources:
        telemetry = _text(source.get("telemetry_dir"))
        key = _canonical_path(telemetry)
        prior_files = _dict(_dict(prior_stores.get(key)).get("files"))
        records, store_cursor = _load_jsonl_paths(
            _span_paths(telemetry),
            {"files": prior_files},
        )
        batches.append(records)
        reset = reset or bool(store_cursor.get("reset"))
        files = dict(prior_files)
        files.update(_dict(store_cursor.get("files")))
        next_stores[key] = {
            "project_id": _text(source.get("project_id")),
            "state_root": _text(source.get("state_root")),
            "telemetry_dir": telemetry,
            "files": files,
        }

    rebuilt = False
    if reset:
        # Preserve the historical all-input rebuild semantics when an append-only
        # invariant breaks. It keeps aggregate contrast correct across stores.
        rebuilt = True
        seen = set()
        batches = []
        # A reset is an all-input rebuild. Stores absent from this rebuild must
        # lose their EOF cursors so a later reappearance starts at byte zero.
        next_stores = {}
        for source in sources:
            telemetry = _text(source.get("telemetry_dir"))
            key = _canonical_path(telemetry)
            records, store_cursor = _load_jsonl_paths(_span_paths(telemetry), None)
            batches.append(records)
            next_stores[key] = {
                "project_id": _text(source.get("project_id")),
                "state_root": _text(source.get("state_root")),
                "telemetry_dir": telemetry,
                "files": _dict(store_cursor.get("files")),
            }

    spans, seen, counts = _dedupe_span_batches(sources, batches, seen)
    ordered_stores = {key: next_stores[key] for key in sorted(next_stores)}
    next_cursor: dict[str, Any] = {
        "schema": SPAN_CURSOR_SCHEMA,
        "stores": ordered_stores,
        # Keep the flat view for older readers while v2 uses ``stores`` as its
        # authoritative per-checkout shape.
        "files": _flatten_span_cursor_files(ordered_stores),
        "seen_span_ids": sorted(seen),
        "identity_version": SPAN_IDENTITY_VERSION,
        "reset": False,
    }
    if rebuilt:
        next_cursor["rebuilt"] = True
    if diagnostics is not None:
        diagnostics.clear()
        diagnostics.update(
            _span_source_diagnostics(
                sources, counts, aggregated=aggregated, discovery=discovery
            )
        )
    return spans, next_cursor


def load_manual_outcomes(log_root: str, day: str | None = None) -> list[dict[str, Any]]:
    path = outcomes_path(log_root)
    out: list[dict[str, Any]] = []
    try:
        with open(path, encoding="utf-8") as handle:
            for line in handle:
                text = line.strip()
                if not text:
                    continue
                try:
                    payload = json.loads(text)
                except ValueError:
                    continue
                if (
                    isinstance(payload, dict)
                    and payload.get("schema") == OUTCOME_SCHEMA
                    and (not day or _text(payload.get("ts")).startswith(day))
                ):
                    out.append(payload)
    except OSError:
        pass
    return out


def load_manual_outcomes_incremental(
    log_root: str,
    *,
    cursor: dict[str, Any] | None = None,
) -> tuple[list[dict[str, Any]], dict[str, Any]]:
    records, next_cursor = _load_jsonl_paths([outcomes_path(log_root)], cursor)
    return [item for item in records if item.get("schema") == OUTCOME_SCHEMA], next_cursor


def build_catalog(repo: str) -> dict[str, Any]:
    return _catalog_module().build_catalog(repo)


def _entity_id(entity: dict[str, Any]) -> str:
    return f"{entity.get('type')}:{entity.get('name')}"


def _entity_index(catalog: dict[str, Any]) -> dict[str, dict[str, Any]]:
    return {
        _entity_id(entity): entity
        for entity in _list(catalog.get("entities"))
        if _text(entity.get("type")) and _text(entity.get("name"))
    }


def _entity_tokens(entity: dict[str, Any]) -> set[str]:
    return _tokenize(
        " ".join(
            [
                _text(entity.get("type")),
                _text(entity.get("name")),
                _text(entity.get("plugin")),
                _text(entity.get("description")),
                os.path.basename(_text(entity.get("source_path"))),
            ]
        )
    )


def infer_entity(text: str, catalog: dict[str, Any]) -> tuple[str, str, float]:
    """Attach free text to the most likely catalog entity.

    Prefer narrower harness entities over plugins when scores tie. This makes
    bugs found in slash commands/agents/skills actionable at the right layer.
    """
    prompt_tokens = _tokenize(text)
    best = ("plugin", "legion-observability", 0.0)
    best_rank = -1
    type_rank = {"command": 5, "agent": 4, "skill": 3, "plugin": 2, "hook": 1, "mcp": 1}
    for entity in _list(catalog.get("entities")):
        etype = _text(entity.get("type"))
        name = _text(entity.get("name"))
        if not etype or not name:
            continue
        tokens = _entity_tokens(entity)
        overlap = prompt_tokens & tokens
        if not overlap:
            continue
        score = float(len(overlap)) + (len(overlap) / max(1, len(prompt_tokens | tokens)))
        rank = type_rank.get(etype, 0)
        if score > best[2] or (score == best[2] and rank > best_rank):
            best = (etype, name, score)
            best_rank = rank
    return best


def _outcome(
    *,
    source: str,
    summary: str,
    evidence: str = "",
    severity: str = "medium",
    target_type: str = "plugin",
    target_name: str = "legion-observability",
    run_id: str = "",
    source_path: str = "",
    metadata: dict[str, Any] | None = None,
) -> dict[str, Any]:
    payload = {
        "schema": OUTCOME_SCHEMA,
        "id": _stable_id([source, target_type, target_name, run_id, summary, evidence]),
        "ts": _iso_utc(),
        "source": source,
        "target_type": target_type,
        "target_name": target_name,
        "severity": _severity(severity),
        "summary": _short(summary, 500),
        "evidence": _short(evidence, 1200),
        "run_id": run_id,
        "source_path": source_path,
        "metadata": metadata or {},
    }
    return payload


def _verdict_outcomes(span: dict[str, Any], catalog: dict[str, Any]) -> list[dict[str, Any]]:
    artifacts = _dict(span.get("artifacts"))
    verdict_path = _text(artifacts.get("verdict"))
    if not verdict_path:
        return []
    verdict = _json_file(os.path.expanduser(verdict_path))
    if not isinstance(verdict, dict):
        if _text(span.get("status")) in SUCCESS_STATUSES:
            return []
        etype, name = target_for_span(span, catalog)
        return [
            _outcome(
                source="review-verdict",
                target_type=etype,
                target_name=name,
                severity="medium",
                summary="Review verdict artifact was referenced but could not be parsed.",
                evidence=verdict_path,
                run_id=_text(span.get("run_id")),
                source_path=verdict_path,
                metadata={"span_status": span.get("status")},
            )
        ]

    findings = _list(verdict.get("findings"))
    verdict_status = _text(verdict.get("verdict")).lower()
    outcomes: list[dict[str, Any]] = []
    if verdict_status in {"request_changes", "fail", "failed", "reject"} and not findings:
        etype, name, _score = infer_entity(
            " ".join([_text(span.get("task")), json.dumps(verdict, sort_keys=True)]),
            catalog,
        )
        outcomes.append(
            _outcome(
                source="review-verdict",
                target_type=etype,
                target_name=name,
                severity="high",
                summary=f"Review verdict requested changes for {span.get('archetype') or 'run'}.",
                evidence=_short(json.dumps(verdict, sort_keys=True), 1000),
                run_id=_text(span.get("run_id")),
                source_path=verdict_path,
                metadata={"verdict": verdict_status},
            )
        )

    for finding in findings:
        if not isinstance(finding, dict):
            continue
        evidence_bits = [
            _text(finding.get("title")),
            _text(finding.get("file")),
            str(finding.get("line") or ""),
            _text(finding.get("detail")),
        ]
        etype, name, _score = infer_entity(
            " ".join([_text(span.get("task")), " ".join(evidence_bits)]),
            catalog,
        )
        outcomes.append(
            _outcome(
                source="review-finding",
                target_type=etype,
                target_name=name,
                severity=_severity(finding.get("severity"), "medium"),
                summary=_text(finding.get("title")) or "Review finding found a harness issue.",
                evidence=" | ".join(bit for bit in evidence_bits if bit),
                run_id=_text(span.get("run_id")),
                source_path=verdict_path,
                metadata={
                    "verdict": verdict_status,
                    "file": finding.get("file"),
                    "line": finding.get("line"),
                },
            )
        )
    return outcomes


def target_for_span(span: dict[str, Any], catalog: dict[str, Any]) -> tuple[str, str]:
    target_type = _text(span.get("target_type"))
    target_name = _text(span.get("target_name"))
    if target_type and target_name:
        return target_type, target_name
    executor = _text(span.get("executor"))
    task = _text(span.get("task")).lower()
    if executor == "codex-review" or task.startswith("review "):
        return "plugin", "legion-router"
    etype, name, _score = infer_entity(_text(span.get("task")), catalog)
    return etype, name


def span_outcomes(spans: list[dict[str, Any]], catalog: dict[str, Any]) -> list[dict[str, Any]]:
    outcomes: list[dict[str, Any]] = []
    for span in spans:
        outcomes.extend(_verdict_outcomes(span, catalog))
        status = _text(span.get("status"))
        if status in SUCCESS_STATUSES:
            continue
        etype, name = target_for_span(span, catalog)
        outcomes.append(
            _outcome(
                source="span-status",
                target_type=etype,
                target_name=name,
                severity="high" if status in {"failed", "error"} else "medium",
                summary=f"Legion run ended with status {status or 'unknown'}.",
                evidence=_short(_text(span.get("task")), 1000),
                run_id=_text(span.get("run_id")),
                metadata={
                    "executor": span.get("executor"),
                    "model": span.get("model"),
                    "archetype": span.get("archetype"),
                    "artifacts": span.get("artifacts"),
                },
            )
        )
    return outcomes


def trigger_eval_outcomes(repo: str, catalog: dict[str, Any]) -> list[dict[str, Any]]:
    evaluator = _eval_module()
    outcomes: list[dict[str, Any]] = []
    for dataset, scope in _eval_datasets(repo):
        if not os.path.exists(dataset):
            continue
        cases = evaluator._load_dataset(dataset)
        targets = evaluator.load_targets(repo, evaluator._scope_for_cases(cases, scope))
        results = [evaluator.evaluate_case(case, targets, 3, 0.5) for case in cases]
        for result in results:
            if result.get("status") == "pass":
                continue
            expect = _text(result.get("expect")) or "legion-observability"
            expect_type = _text(result.get("expect_type")) or "plugin"
            top = result.get("top")
            evidence = {
                "dataset": os.path.basename(dataset),
                "prompt": result.get("prompt"),
                "expect_type": expect_type,
                "expect": expect,
                "got_type": result.get("got_type"),
                "got": result.get("got"),
                "top": top,
            }
            outcomes.append(
                _outcome(
                    source="trigger-eval",
                    target_type=expect_type,
                    target_name=expect,
                    severity="medium" if result.get("status") == "collision" else "high",
                    summary=(
                        f"Trigger eval {result.get('status')}: expected "
                        f"{expect_type}:{expect}, got {result.get('got_type')}:{result.get('got')}."
                    ),
                    evidence=json.dumps(evidence, sort_keys=True),
                    metadata={"status": result.get("status"), "dataset": os.path.basename(dataset)},
                )
            )
    return outcomes


def routing_outcomes(
    repo: str, log_root: str, spans: list[dict[str, Any]] | None = None
) -> list[dict[str, Any]]:
    try:
        optimizer = _optimize_module(repo)
        if spans is None:
            spans = optimizer.load_spans(os.path.join(os.path.expanduser(log_root), "spans"))
        routing = optimizer.load_routing(
            os.path.join(repo, "legion-router", "config", "routing.toml")
        )
        proposals = optimizer.optimize(spans, routing)
    except Exception as exc:  # pragma: no cover - defensive report path
        return [
            _outcome(
                source="routing-optimizer",
                target_type="plugin",
                target_name="legion-router",
                severity="medium",
                summary="Routing optimizer could not run.",
                evidence=str(exc),
            )
        ]

    outcomes: list[dict[str, Any]] = []
    for archetype, proposal in proposals.items():
        if _text(proposal.get("decision")) != "accept":
            continue
        outcomes.append(
            _outcome(
                source="routing-optimizer",
                target_type="plugin",
                target_name="legion-router",
                severity="low",
                summary=(
                    f"Routing optimizer accepts {archetype}: "
                    f"{proposal.get('current_model')} -> {proposal.get('proposed_model')}."
                ),
                evidence=json.dumps(proposal, sort_keys=True),
                metadata={"archetype": archetype, "proposal": proposal},
            )
        )
    return outcomes


def learning_law_outcomes(repo: str) -> list[dict[str, Any]]:
    """Translate promoted, cross-project laws into the existing proposal lane."""
    state = legion_state.resolve_state(repo)
    payload = _json_file(os.path.join(state["global_learning_dir"], "laws.json"))
    laws = _list(payload.get("laws")) if isinstance(payload, dict) else []
    outcomes: list[dict[str, Any]] = []
    for law in laws:
        if not isinstance(law, dict) or law.get("status") != "active":
            continue
        key = _text(law.get("key"))
        if not key:
            continue
        support = _dict(law.get("support"))
        try:
            episodes = int(support.get("episodes") or 0)
            projects = int(support.get("projects") or 0)
            confidence = float(law.get("confidence") or 0.0)
        except (TypeError, ValueError):
            continue
        if not math.isfinite(confidence) or episodes < 0 or projects < 0:
            continue
        outcomes.append(
            _outcome(
                source="learning-law",
                target_type="plugin",
                target_name="legion-observability",
                severity="high" if confidence >= 0.9 else "medium",
                summary=(
                    f"Promoted learning law '{key}' from {episodes} episode(s) "
                    f"across {projects} project(s)."
                ),
                evidence=json.dumps(
                    {
                        "support": support,
                        "evidence_ids": _list(law.get("evidence_ids"))[:20],
                    },
                    sort_keys=True,
                ),
                metadata={
                    "law_key": key,
                    "confidence": confidence,
                    "support": support,
                    "guidance": _text(law.get("guidance")),
                    "validation": _text(law.get("validation")),
                },
            )
        )
    return outcomes


def learning_law_lifecycle(repo: str) -> dict[str, str] | None:
    """Return the complete bounded law lifecycle, including retired laws.

    Returns ``None`` when the law store could not be read at all -- no global
    directory, a missing or unreadable ``laws.json``, or a malformed document.
    That is deliberately distinct from an empty mapping, which means "read
    successfully, and no laws exist". Callers use the difference to avoid
    treating an unreadable store as proof that every law was retired, which
    would delete queued proposals and retire live hints on a transient fault.
    """
    state = legion_state.resolve_state(repo)
    global_dir = _text(state.get("global_learning_dir"))
    if not global_dir:
        return None
    payload = _json_file(os.path.join(global_dir, "laws.json"))
    if not isinstance(payload, dict):
        return None
    result: dict[str, str] = {}
    for law in _list(_dict(payload).get("laws"))[
        : legion_learning_context.MAX_HINTS
        + legion_learning_context.MAX_EXCLUDED_HINTS
    ]:
        if not isinstance(law, dict):
            continue
        key = _short(_text(law.get("key")), 160)
        status = _short(_text(law.get("status")), 40)
        if key and status:
            result[key] = status
    return result


def _proc_result(name: str, argv: list[str], repo: str, timeout: int = 60) -> dict[str, Any]:
    started = time.monotonic()
    try:
        proc = subprocess.run(
            argv,
            cwd=repo,
            text=True,
            capture_output=True,
            timeout=timeout,
            check=False,
        )
    except (OSError, subprocess.TimeoutExpired) as exc:
        return {
            "name": name,
            "cmd": argv,
            "ok": False,
            "error": str(exc),
            "duration_ms": round((time.monotonic() - started) * 1000),
        }
    return {
        "name": name,
        "cmd": argv,
        "ok": proc.returncode == 0,
        "returncode": proc.returncode,
        "stdout": proc.stdout[-20000:],
        "stderr": proc.stderr[-20000:],
        "duration_ms": round((time.monotonic() - started) * 1000),
    }


def _aggregate_eval_summaries(summaries: list[dict[str, Any]]) -> dict[str, Any]:
    cases = sum(int(summary.get("cases") or 0) for summary in summaries)
    passed = sum(int(summary.get("pass") or 0) for summary in summaries)
    collision = sum(int(summary.get("collision") or 0) for summary in summaries)
    miss = sum(int(summary.get("miss") or 0) for summary in summaries)
    hit_weighted = sum(
        float(summary.get("hit_at_k") or 0.0) * int(summary.get("cases") or 0)
        for summary in summaries
    )
    precision = round(passed / cases, 3) if cases else 0.0
    hit_at_k = round(hit_weighted / cases, 3) if cases else 0.0
    return {
        "cases": cases,
        "pass": passed,
        "collision": collision,
        "miss": miss,
        "precision_at_1": precision,
        "hit_at_k": hit_at_k,
        "pass_rate": precision,
    }


def empty_scorecard(
    repo: str, *, reason: str = "", measurement: str = ""
) -> dict[str, Any]:
    """Build a scorecard with no measured cases.

    Scorecard v2 uses measurement="unmeasured" when nothing could be scored at
    all and reports score=None rather than 0.0. A literal 0.0 reads to the
    keep/discard gate as "measured, and it regressed to zero", which is the
    opposite of the truth when no measurement ever ran. Readers remain tolerant
    of stored v1 cards because a missing measurement still means "measured".
    """
    unmeasured = measurement == "unmeasured"
    card: dict[str, Any] = {
        "schema": SCORECARD_SCHEMA,
        "generated_at": _iso_utc(),
        "repo": os.path.abspath(repo),
        "ok": False,
        "score": None if unmeasured else 0.0,
        "metrics": {
            "cases": 0,
            "pass": 0,
            "collision": 0,
            "miss": 0,
            "precision_at_1": 0.0,
            "hit_at_k": 0.0,
            "pass_rate": 0.0,
            "false_success": 0,
            "safety_regressions": 0,
            "duration_ms": 0,
        },
        "checks": [],
        "reason": reason,
    }
    if unmeasured:
        card["measurement"] = "unmeasured"
    return card


def _engine_or_repo_path(repo: str, repo_path: str, engine_path: str) -> str:
    """Resolve executable scorecard tools from the trusted engine first."""
    engine_candidate = os.path.abspath(os.path.join(_here(), engine_path))
    if os.path.isfile(engine_candidate):
        return engine_candidate
    # Engine-first is the safe order: ``repo`` is the untrusted checkout being
    # scored, while ``_here()`` is the code already chosen to run. Development
    # checkouts still use their own tools because their running engine is here.
    repo_candidate = os.path.abspath(os.path.join(repo, repo_path))
    return repo_candidate if os.path.isfile(repo_candidate) else ""


def _eval_datasets(repo: str) -> list[tuple[str, str]]:
    """Resolve only the scored repo's datasets, preferring its vendored copy.

    Eval cases describe the target's skill surface.  The engine's calibrated
    legion-core cases are therefore not a valid fallback for a consumer repo:
    they can turn an absent measurement into a fabricated regression.
    """
    datasets: list[tuple[str, str]] = []
    for name, scope in (
        ("skill-triggering.yaml", "auto"),
        ("entity-triggering.yaml", "entity"),
    ):
        # `legion-eval/`, not `.legion/eval/`: `.legion/` is Legion's runtime
        # directory for runs and worktrees and is conventionally git-ignored, so
        # a dataset placed there can never be committed or shipped. Scoring
        # config is source, not runtime state.
        for directory in (
            os.path.join(repo, "legion-observability", "eval"),
            os.path.join(repo, "legion-eval"),
        ):
            candidate = os.path.abspath(os.path.join(directory, name))
            if os.path.isfile(candidate):
                datasets.append((candidate, scope))
                break
    return datasets


def run_scorecard(repo: str) -> dict[str, Any]:
    """Run Legion's daily deterministic scorecard.

    This is the local analogue of harness-bench's scorecard run and
    autoresearch's fixed metric run: same datasets, same checks, compact metrics.
    """
    repo = os.path.abspath(repo)
    eval_script = _engine_or_repo_path(
        repo,
        os.path.join("legion-observability", "scripts", "legion-eval.py"),
        "legion-eval.py",
    )
    doctor_script = _engine_or_repo_path(
        repo,
        os.path.join("legion-observability", "scripts", "legion-doctor.sh"),
        "legion-doctor.sh",
    )
    if not eval_script:
        return empty_scorecard(
            repo, reason="missing engine legion-eval", measurement="unmeasured"
        )

    checks: list[dict[str, Any]] = []
    summaries: list[dict[str, Any]] = []
    datasets = _eval_datasets(repo)
    for dataset, scope in datasets:
        name = f"legion-eval:{os.path.basename(dataset)}"
        check = _proc_result(
            name,
            [
                sys.executable,
                eval_script,
                "--repo",
                repo,
                "--dataset",
                dataset,
                "--scope",
                scope,
                "--json",
            ],
            repo,
        )
        if check.get("ok"):
            try:
                payload = json.loads(_text(check.get("stdout")))
            except ValueError:
                payload = {}
            summary = _dict(payload.get("summary"))
            check["summary"] = summary
            summaries.append(summary)
        checks.append(check)

    if doctor_script:
        checks.append(_proc_result("legion-doctor", ["bash", doctor_script, "--repo", repo], repo))

    metrics = _aggregate_eval_summaries(summaries)
    metrics.update(
        {
            "false_success": metrics["collision"],
            "safety_regressions": sum(
                1 for check in checks if check.get("name") == "legion-doctor" and not check.get("ok")
            ),
            "duration_ms": sum(int(check.get("duration_ms") or 0) for check in checks),
        }
    )
    if not datasets:
        return {
            "schema": SCORECARD_SCHEMA,
            "generated_at": _iso_utc(),
            "repo": repo,
            "ok": False,
            "measurement": "unmeasured",
            "score": None,
            "metrics": metrics,
            "checks": checks,
            "reason": "no eval dataset in repo",
        }
    # A check that never completed -- timeout, missing interpreter, OSError --
    # carries "error" instead of "returncode". That is an infrastructure
    # failure, not evidence about the code being scored. Reporting it as a
    # measured ok=false would be a false regression by a second route, exactly
    # the failure mode the dataset fix above exists to prevent.
    incomplete = [c for c in checks if "error" in c and "returncode" not in c]
    if incomplete:
        return {
            "schema": SCORECARD_SCHEMA,
            "generated_at": _iso_utc(),
            "repo": repo,
            "ok": False,
            "measurement": "unmeasured",
            "score": None,
            "metrics": metrics,
            "checks": checks,
            "reason": "check did not complete: "
            + ", ".join(sorted(_text(c.get("name")) for c in incomplete)),
        }
    ok = bool(summaries) and all(bool(check.get("ok")) for check in checks)
    return {
        "schema": SCORECARD_SCHEMA,
        "generated_at": _iso_utc(),
        "repo": repo,
        "ok": ok,
        "measurement": "measured",
        "score": metrics["precision_at_1"] if ok else 0.0,
        "metrics": metrics,
        "checks": checks,
    }


def dedupe_outcomes(outcomes: list[dict[str, Any]]) -> list[dict[str, Any]]:
    by_id: dict[str, dict[str, Any]] = {}
    for outcome in outcomes:
        oid = _text(outcome.get("id")) or _stable_id([outcome])
        current = by_id.get(oid)
        if current is None:
            by_id[oid] = outcome
            continue
        if SEVERITY_ORDER[_severity(outcome.get("severity"))] > SEVERITY_ORDER[
            _severity(current.get("severity"))
        ]:
            by_id[oid] = outcome
    return sorted(
        by_id.values(),
        key=lambda item: (
            -SEVERITY_ORDER[_severity(item.get("severity"))],
            _text(item.get("target_type")),
            _text(item.get("target_name")),
            _text(item.get("summary")),
        ),
    )


def _marketplace_path_for_entity(entity: dict[str, Any]) -> str:
    source_path = _text(entity.get("source_path"))
    if not source_path:
        return ""
    current = source_path if os.path.isdir(source_path) else os.path.dirname(source_path)
    while current and current != os.path.dirname(current):
        candidate = os.path.join(current, ".claude-plugin", "marketplace.json")
        if os.path.exists(candidate):
            return candidate
        current = os.path.dirname(current)
    return ""


def proposal_for_outcome(outcome: dict[str, Any], catalog: dict[str, Any]) -> dict[str, Any]:
    target_type = _text(outcome.get("target_type")) or "plugin"
    target_name = _text(outcome.get("target_name")) or "legion-observability"
    entity = _entity_index(catalog).get(f"{target_type}:{target_name}", {})
    source = _text(outcome.get("source"))
    source_path = _text(entity.get("source_path"))
    proposal_identity = outcome.get("id")
    law_key = ""

    if source == "trigger-eval":
        kind = "trigger_description_fix"
        if target_type == "plugin":
            source_path = _marketplace_path_for_entity(entity) or source_path
        suggested = (
            "Tighten the entity description/frontmatter with distinguishing trigger "
            "terms from the failed prompt, and remove ambiguous generic wording that "
            "overlaps the winning entity."
        )
        validation = "Run legion-eval and require no new miss/collision for this case."
    elif source == "routing-optimizer":
        kind = "routing_policy_update"
        suggested = (
            "Review the accepted routing optimizer delta and update routing.toml only "
            "if the sample count and quality bar are trusted."
        )
        validation = "Run legion-optimize --json and tests/python/test_legion_optimize.py."
    elif source in {"review-finding", "review-verdict"}:
        kind = "review_guardrail"
        suggested = (
            "Add a specific guardrail or checklist item to the target command/agent/skill "
            "so future runs catch this finding before final review."
        )
        validation = "Replay the relevant workflow or run the smallest affected eval/test."
    elif source == "learning-law":
        kind = "learned_behavior_guardrail"
        metadata = _dict(outcome.get("metadata"))
        law_key = _text(metadata.get("law_key"))
        if law_key:
            proposal_identity = f"learning-law:{law_key}"
        suggested = _text(metadata.get("guidance")) or (
            "Turn the promoted cross-project behavior into a scoped, durable harness guardrail."
        )
        validation = _text(metadata.get("validation")) or (
            "Replay representative supporting workflows before proposing a reviewed change."
        )
    elif source == "span-status":
        kind = "run_failure_guardrail"
        # Name the run that actually failed. Every span-status outcome otherwise
        # renders the same sentence, so a project accumulates several hints whose
        # text is byte-identical — they survive dedupe (identity is the outcome
        # id, not the text) and then spend the hint budget saying nothing about
        # the failure they came from. The legion-run branch below already carries
        # its stage into the guidance for the same reason.
        span_metadata = _dict(outcome.get("metadata"))
        failed_on = ", ".join(
            part
            for part in (
                _short(_text(span_metadata.get("archetype")), 40),
                _short(_text(span_metadata.get("executor")), 40),
                _short(_text(span_metadata.get("model")), 40),
            )
            if part
        )
        context = f" (observed on {failed_on})" if failed_on else ""
        suggested = (
            f"Teach the target harness entity to detect this run failure{context} "
            "early: emit a clearer artifact, or route to a stronger validator "
            "before returning."
        )
        validation = "Run legion-doctor, legion-eval, and a targeted delegated smoke run."
    elif source.startswith("legion-run:"):
        kind = "run_stage_guardrail"
        stage = _short(source.split(":", 1)[1], 40) or "stage"
        suggested = (
            f"Prevent this {stage} failure recurring: address the recorded cause in the "
            "target entity before the next run reaches that stage."
        )
        validation = f"Re-run the failing legion-run {stage} stage and require it to pass."
    else:
        kind = "memory_guardrail"
        suggested = (
            "Record the issue as a reusable harness memory and turn it into a source "
            "patch when it repeats or blocks work."
        )
        validation = "Run the target entity's normal validation before proposing a reviewed change."

    proposal = {
        "id": _stable_id(["proposal", proposal_identity, kind]),
        "kind": kind,
        "status": "proposed",
        "target_type": target_type,
        "target_name": target_name,
        "source_path": source_path,
        "summary": outcome.get("summary"),
        "evidence": outcome.get("evidence"),
        "severity": _severity(outcome.get("severity")),
        "suggested_change": suggested,
        "validation": validation,
        "outcome_id": outcome.get("id"),
    }
    if law_key:
        proposal["law_key"] = law_key
    return proposal


def _improvement_target(repo: str, source_path: str) -> str:
    """Return a safe repo-relative Markdown target or an empty string."""
    repo_abs = os.path.abspath(repo)
    candidate = (
        os.path.abspath(
            source_path if os.path.isabs(source_path) else os.path.join(repo_abs, source_path)
        )
        if source_path
        else ""
    )
    if candidate and os.path.isdir(candidate):
        for name in ("SKILL.md", "README.md"):
            nested = os.path.join(candidate, name)
            if os.path.isfile(nested):
                candidate = nested
                break
    if (
        not candidate
        or not os.path.isfile(candidate)
        or not candidate.endswith(".md")
        or not _path_in_repo(candidate, repo_abs)
        or _path_uses_symlink(candidate, repo_abs)
        or f"{os.sep}vendored{os.sep}" in candidate
    ):
        return ""
    relative = os.path.relpath(candidate, repo_abs)
    if relative == ".." or relative.startswith(f"..{os.sep}") or relative.startswith(f".legion{os.sep}"):
        return ""
    return relative.replace(os.sep, "/")


def typed_improvement_proposal(
    outcome: dict[str, Any], proposal: dict[str, Any], repo: str
) -> dict[str, Any] | None:
    """Promote only well-supported learning laws into the review-only queue.

    Ordinary failures and model prose remain memory. The first source-changing
    lane requires an active cross-project law with high confidence, at least
    five episodes, and at least three independent projects.
    """
    if _text(outcome.get("source")) != "learning-law":
        return None
    metadata = _dict(outcome.get("metadata"))
    support = _dict(metadata.get("support"))
    try:
        confidence = float(metadata.get("confidence") or 0.0)
        episodes = int(support.get("episodes") or 0)
        projects = int(support.get("projects") or 0)
    except (TypeError, ValueError):
        return None
    guidance = _short(_text(metadata.get("guidance")), 500)
    target = _improvement_target(repo, _text(proposal.get("source_path")))
    if (
        not math.isfinite(confidence)
        or confidence < 0.9
        or episodes < 5
        or projects < 3
        or not guidance
        or not target
    ):
        return None
    try:
        evidence = json.loads(_text(outcome.get("evidence")))
    except ValueError:
        evidence = {}
    evidence_ids = [
        _short(_text(value), 160)
        for value in _list(_dict(evidence).get("evidence_ids"))[:20]
        if _text(value)
    ]
    law_key = _text(metadata.get("law_key"))
    return {
        "schema": IMPROVEMENT_PROPOSAL_SCHEMA,
        "id": f"learning-law:{_stable_id([law_key or proposal.get('id')])}",
        "revision": episodes,
        "maintainer_eligible": True,
        "kind": "documentation_guardrail",
        "summary": _short(_text(proposal.get("summary")), 500),
        "target": {"path": target},
        "candidate": {
            "operation": "append_markdown_guardrail",
            "content": guidance,
        },
        "validation": {"profile": "documentation"},
        "limits": {"max_changed_lines": 40},
        "provenance": {
            "source": "learning-law",
            "source_id": _stable_id(["learning-law", law_key]),
            "law_key": law_key,
            "confidence": confidence,
            "support": {"episodes": episodes, "projects": projects},
            "evidence_ids": evidence_ids,
        },
    }


def write_improvement_queue(report: dict[str, Any], log_root: str) -> list[str]:
    queue_dir = improvement_queue_dir(log_root)
    _ensure_dir(queue_dir)
    lifecycle = _dict(report.get("learning_laws"))
    has_lifecycle = "learning_laws" in report
    proposals = [
        proposal
        for proposal in _list(report.get("improvement_proposals"))
        if isinstance(proposal, dict)
        and (
            not has_lifecycle
            or _dict(proposal.get("provenance")).get("source") != "learning-law"
            or lifecycle.get(
                _text(_dict(proposal.get("provenance")).get("law_key"))
            )
            == "active"
        )
    ]
    proposal_entries = [
        (
            proposal,
            hashlib.sha256(
                json.dumps(
                    proposal,
                    sort_keys=True,
                    separators=(",", ":"),
                    ensure_ascii=True,
                ).encode("utf-8")
            ).hexdigest(),
        )
        for proposal in proposals
    ]
    current_law_files = {
        _text(_dict(proposal.get("provenance")).get("law_key")): (
            f"{fingerprint}.json"
        )
        for proposal, fingerprint in proposal_entries
        if _dict(proposal.get("provenance")).get("source") == "learning-law"
        and _text(_dict(proposal.get("provenance")).get("law_key"))
    }
    lock_path = os.path.join(queue_dir, ".queue.lock")
    with open(lock_path, "a+", encoding="utf-8") as lock, legion_file_lock.exclusive_lock(lock):
        if has_lifecycle:
            # Reconcile only Legion-generated law proposals. Maintainer-authored
            # queue entries are never removed by the learning loop. Exactly one
            # current revision is retained for each emitted active law.
            for entry in list(os.scandir(queue_dir))[:10_000]:
                if not entry.is_file(follow_symlinks=False) or not entry.name.endswith(".json"):
                    continue
                queued = _json_file(entry.path)
                provenance = _dict(_dict(queued).get("provenance"))
                if provenance.get("source") != "learning-law":
                    continue
                law_key = _text(provenance.get("law_key"))
                if (
                    law_key
                    and (
                        lifecycle.get(law_key) != "active"
                        or (
                            law_key in current_law_files
                            and current_law_files[law_key] != entry.name
                        )
                    )
                ):
                    try:
                        os.unlink(entry.path)
                    except FileNotFoundError:
                        pass
        written: list[str] = []
        for proposal, fingerprint in proposal_entries:
            path = os.path.join(queue_dir, f"{fingerprint}.json")
            _write_json(path, proposal)
            written.append(path)
    return written


def trace_contrast(spans: list[dict[str, Any]], catalog: dict[str, Any]) -> dict[str, Any]:
    """Summarize pass/fail patterns by entity for future proposal generation."""
    entities: dict[str, dict[str, Any]] = {}
    for span in spans:
        etype, name = target_for_span(span, catalog)
        key = f"{etype}:{name}"
        entry = entities.setdefault(
            key,
            {
                "target_type": etype,
                "target_name": name,
                "ok": 0,
                "failed": 0,
                "statuses": {},
                "success_examples": [],
                "failure_examples": [],
            },
        )
        status = _text(span.get("status")) or "unknown"
        entry["statuses"][status] = int(entry["statuses"].get(status, 0)) + 1
        bucket = "ok" if status in SUCCESS_STATUSES else "failed"
        entry[bucket] += 1
        examples_key = "success_examples" if bucket == "ok" else "failure_examples"
        if len(entry[examples_key]) < 3:
            entry[examples_key].append(
                {
                    "run_id": span.get("run_id"),
                    "executor": span.get("executor"),
                    "model": span.get("model"),
                    "task": _short(_text(span.get("task")), 220),
                }
            )
    return {"entities": dict(sorted(entities.items()))}


def merge_trace_contrast(
    historical: dict[str, Any], current: dict[str, Any]
) -> dict[str, Any]:
    merged: dict[str, dict[str, Any]] = {}
    keys = set(_dict(_dict(historical).get("entities"))) | set(
        _dict(_dict(current).get("entities"))
    )
    for key in sorted(keys):
        old = _dict(_dict(_dict(historical).get("entities")).get(key))
        new = _dict(_dict(_dict(current).get("entities")).get(key))
        statuses: dict[str, int] = defaultdict(int)
        for source in (_dict(old).get("statuses"), _dict(new).get("statuses")):
            for status, count in _dict(source).items():
                statuses[str(status)] += int(count or 0)
        merged[key] = {
            "target_type": new.get("target_type") or old.get("target_type"),
            "target_name": new.get("target_name") or old.get("target_name"),
            "ok": int(old.get("ok") or 0) + int(new.get("ok") or 0),
            "failed": int(old.get("failed") or 0) + int(new.get("failed") or 0),
            "statuses": dict(sorted(statuses.items())),
            "success_examples": (
                _list(old.get("success_examples"))
                + _list(new.get("success_examples"))
            )[:3],
            "failure_examples": (
                _list(old.get("failure_examples"))
                + _list(new.get("failure_examples"))
            )[:3],
        }
    return {"entities": merged}


def build_report(
    repo: str,
    log_root: str,
    day: str | None = None,
    *,
    scan_all: bool = False,
    include_processed: bool = False,
    telemetry_dir: str = "",
) -> dict[str, Any]:
    day = day or _date_utc()
    catalog = build_catalog(repo)
    scan_day = None if scan_all else day
    memory = load_memory(log_root)
    incremental = bool(scan_all and not include_processed)
    input_cursor: dict[str, Any] = {}
    input_cursor_base: dict[str, Any] = {}
    span_source_report: dict[str, Any] = {}
    bootstrap_trace_contrast = False
    if incremental:
        prior_cursor = _dict(memory.get("input_cursor"))
        input_cursor_base = prior_cursor
        prior_span_cursor = _dict(prior_cursor.get("spans"))
        bootstrap_trace_contrast = bool(
            _dict(_dict(memory.get("trace_contrast")).get("entities"))
            and not prior_span_cursor
        )
        spans, span_cursor = load_spans_incremental(
            log_root,
            telemetry_dir=telemetry_dir,
            cursor=_dict(prior_cursor.get("spans")),
            repo=repo,
            diagnostics=span_source_report,
        )
        manual_outcomes, outcome_cursor = load_manual_outcomes_incremental(
            log_root,
            cursor=_dict(prior_cursor.get("manual_outcomes")),
        )
        input_cursor = {
            "schema": INPUT_CURSOR_SCHEMA,
            "spans": span_cursor,
            "manual_outcomes": outcome_cursor,
        }
    else:
        spans = load_spans(
            log_root,
            scan_day,
            telemetry_dir=telemetry_dir,
            repo=repo,
            diagnostics=span_source_report,
        )
        manual_outcomes = load_manual_outcomes(log_root, scan_day)
    outcomes = dedupe_outcomes(
        span_outcomes(spans, catalog)
        + trigger_eval_outcomes(repo, catalog)
        + routing_outcomes(repo, log_root, spans)
        + manual_outcomes
        + learning_law_outcomes(repo)
    )
    if not include_processed:
        processed = set(_list(memory.get("processed_outcome_ids")))
        outcomes = [outcome for outcome in outcomes if outcome.get("id") not in processed]
    proposals = [proposal_for_outcome(outcome, catalog) for outcome in outcomes]
    improvement_proposals = [
        typed
        for outcome, proposal in zip(outcomes, proposals)
        if (typed := typed_improvement_proposal(outcome, proposal, repo)) is not None
    ]
    by_entity: dict[str, int] = defaultdict(int)
    for outcome in outcomes:
        by_entity[f"{outcome['target_type']}:{outcome['target_name']}"] += 1
    current_contrast = trace_contrast(spans, catalog)
    if bootstrap_trace_contrast:
        # A pre-cursor memory already summarizes the history we are replaying
        # to establish byte offsets. Preserve that aggregate and add only
        # timestamped spans that are newer than the memory snapshot. Real
        # telemetry has ``ts``; excluding undated replay is safer than silently
        # double-counting historical observations.
        memory_cutoff = _text(memory.get("updated_at"))
        post_memory_spans = [
            span
            for span in spans
            if memory_cutoff and _text(span.get("ts")) > memory_cutoff
        ]
        contrast = merge_trace_contrast(
            _dict(memory.get("trace_contrast")),
            trace_contrast(post_memory_spans, catalog),
        )
    elif incremental and not _dict(input_cursor.get("spans")).get("rebuilt"):
        contrast = merge_trace_contrast(
            _dict(memory.get("trace_contrast")), current_contrast
        )
    else:
        contrast = current_contrast
    report = {
        "schema": "legion.self-learning.report.v1",
        "generated_at": _iso_utc(),
        "day": day,
        "repo": os.path.abspath(repo),
        "log_root": os.path.expanduser(log_root),
        "scan_scope": "all" if scan_all else day,
        "incremental": incremental,
        "spans": len(spans),
        "span_sources": span_source_report,
        "catalog_entities": len(_list(catalog.get("entities"))),
        "outcomes": outcomes,
        "proposals": proposals,
        "improvement_proposals": improvement_proposals,
        "by_entity": dict(sorted(by_entity.items())),
        "scorecard": run_scorecard(repo),
        "trace_contrast": contrast,
    }
    if input_cursor:
        report["input_cursor"] = input_cursor
        report["input_cursor_base"] = input_cursor_base
    # Only publish a lifecycle the loop actually read. Consumers treat the
    # absence of this key as "lifecycle unknown" and skip every reconciliation
    # that would otherwise retire hints or delete queued proposals, so a
    # transient read failure degrades to a no-op instead of a purge.
    lifecycle = learning_law_lifecycle(repo)
    if lifecycle is not None:
        report["learning_laws"] = lifecycle
    return report


def _empty_memory() -> dict[str, Any]:
    return {
        "schema": MEMORY_SCHEMA,
        "created_at": _iso_utc(),
        "updated_at": _iso_utc(),
        "entities": {},
        "processed_outcome_ids": [],
        "reports": [],
        "input_cursor": {},
        "trace_contrast": {"entities": {}},
    }


def load_memory(log_root: str) -> dict[str, Any]:
    payload = _json_file(memory_path(log_root))
    if isinstance(payload, dict) and payload.get("schema") == MEMORY_SCHEMA:
        return payload
    return _empty_memory()


_GUIDANCE_WHITESPACE = re.compile(r"\s+")


def _guidance_text(value: Any, limit: int = 360) -> str:
    """Flatten one guidance string for prompt delivery.

    Guidance is rendered as a single bullet line inside an executor prompt, so
    embedded newlines and control characters would let a summary break out of
    the surrounding list structure. Collapse them before the length bound
    rather than after, so the bound applies to what is actually delivered.
    """
    text = _text(value)
    if not text:
        return ""
    # Drop C0/C1 controls and every Unicode format character. The format class
    # (Cf) covers bidirectional overrides and zero-width joiners, which are
    # printable to this filter and invisible to `\s`, yet let a bullet render
    # differently from its bytes to anyone auditing hints.json or reading the
    # prompt. Surrogates are dropped for the same reason.
    text = "".join(
        char
        for char in text
        # Tab, newline and carriage return are kept here so the collapse below
        # turns them into a single separating space; dropping them outright
        # would run adjacent words together.
        if char in "\t\n\r"
        or unicodedata.category(char) not in {"Cc", "Cf", "Cs"}
    )
    return _short(_GUIDANCE_WHITESPACE.sub(" ", text).strip(), limit)


# The complete set of sentences core composes for a run outcome. Validating a
# record's provenance_summary against these on READ -- not merely trusting the
# marker written at construction -- means a hand-edited or forged outcomes.jsonL
# entry cannot smuggle chosen text into trusted guidance: an unrecognized
# sentence is simply not first-party, and promotion falls back to Legion's fixed
# guardrail. Keep in sync with the producers in legion-run.py.
_CORE_SENTENCE = re.compile(
    r"legion-doctor check [A-Za-z0-9._:-]{1,80} failed\.|"
    r"legion-run failed at [A-Za-z0-9._:-]{1,80}\.|"
    r"legion-fanout reported \d{1,9} failed slice\(s\) and \d{1,9} apply conflict\(s\)\."
)


def _core_composed_sentence(value: Any) -> str:
    """Return the summary only when it is one core itself is known to produce."""
    text = _guidance_text(value)
    return text if text and _CORE_SENTENCE.fullmatch(text) else ""


def _first_party_outcome(outcome: dict[str, Any]) -> bool:
    """True only when core composed the summary from deterministic tooling.

    Records written before this marker existed carry no ``provenance`` field and
    are treated as untrusted, so an upgrade can never retroactively promote old
    extension prose into trusted executor guidance.

    The marker itself is not an authentication token -- any process that can
    write outcomes.jsonl can assert it, as it could already assert
    ``source: "manual"``. What bounds the damage is that the accompanying
    ``provenance_summary`` is re-validated on read against the closed set of
    sentences core actually composes, so asserting the marker over chosen text
    gains nothing.
    """
    return _text(outcome.get("provenance")) == "first-party"


def _hint_from_proposal(proposal: dict[str, Any]) -> str:
    summary = _guidance_text(proposal.get("summary"))
    suggested = _guidance_text(proposal.get("suggested_change"))
    return _short(" ".join(part for part in [summary, f"Suggested: {suggested}" if suggested else ""] if part), 360)


def _typed_hint_from_proposal(
    proposal: dict[str, Any], outcome: dict[str, Any]
) -> dict[str, Any] | None:
    """Promote safe memory into the typed runtime store.

    ``--apply-memory`` is the explicit promotion boundary. Deterministic source
    classes may include their bounded summary; model-authored review prose is
    reduced to Legion's fixed suggested guardrail before becoming trusted
    executor guidance.
    """
    target_type = _short(_text(proposal.get("target_type")), 80)
    target_name = _short(_text(proposal.get("target_name")), 160)
    proposal_id = _short(_text(proposal.get("id")), 120)
    source = _text(outcome.get("source"))
    if not target_type or not target_name or not proposal_id:
        return None
    suggested = _guidance_text(proposal.get("suggested_change"))
    # Deterministic source classes may carry their bounded summary: operator
    # entered notes, the fixed session-learn rule set, and promoted
    # cross-project laws all originate as text Legion composed or curated.
    #
    # A run outcome is different. Its human-facing summary quotes third-party
    # detail -- a doctor message naming a plugin, a slice error, a reviewer
    # finding -- so it is never promoted. What may be promoted is the separate
    # core-composed sentence the producer supplied alongside it, which contains
    # only identifiers core controls.
    first_party = _core_composed_sentence(outcome.get("provenance_summary"))
    if source in {"manual", "session-learn", "learning-law"}:
        guidance = _hint_from_proposal(proposal)
    elif _first_party_outcome(outcome) and first_party:
        guidance = _short(
            " ".join(part for part in [first_party, f"Suggested: {suggested}" if suggested else ""] if part),
            360,
        )
    else:
        guidance = suggested
    if not guidance:
        return None
    scope = "global" if source == "learning-law" else "exact"
    hint: dict[str, Any] = {
        "schema": legion_learning_context.HINT_SCHEMA,
        "id": f"memory:{_stable_id([proposal_id])}",
        "scope": scope,
        "status": "active",
        "trusted": True,
        "guidance": guidance,
        "evidence_ids": [
            value
            for value in (
                _short(_text(outcome.get("id")), 160),
                _short(proposal_id, 160),
            )
            if value
        ],
        "origin": "self-learn-memory",
    }
    if scope == "exact":
        hint["entity"] = f"{target_type}:{target_name}"
    law_key = _short(_text(_dict(outcome.get("metadata")).get("law_key")), 160)
    if law_key:
        hint["law_key"] = law_key
    stage = _text(_dict(outcome.get("metadata")).get("stage"))
    stage = {
        "fanout-apply": "fanout",
        "final-review": "review",
    }.get(stage, stage)
    if stage in {"plan", "fanout", "validate", "review"}:
        hint["stage"] = stage
    return hint


def sync_typed_hints(
    report: dict[str, Any], project_learning_dir: str
) -> dict[str, Any]:
    """Merge promoted memory hints without overwriting maintainer-owned hints."""
    path = os.path.join(project_learning_dir, "hints.json")
    _ensure_dir(project_learning_dir)
    lock_path = os.path.join(project_learning_dir, ".hints.lock")
    with open(lock_path, "a+", encoding="utf-8") as lock, legion_file_lock.exclusive_lock(lock):
        existing = legion_learning_context.read_bounded_json(
            path, legion_learning_context.MAX_HINT_DOCUMENT_BYTES
        )
        # An unreadable store is not an empty one. read_bounded_json returns
        # None for a document that is oversized, truncated, or not an object --
        # exactly the states in which the maintainer-owned hints it holds are
        # most worth preserving. Treating that as "no hints yet" and writing
        # this run's promotions over the top silently destroys them, so refuse
        # to write and surface the condition instead.
        if existing is None and os.path.exists(path):
            return {
                "path": path,
                "promoted": 0,
                "rejected": 0,
                "rejected_ids": [],
                "total": 0,
                "project_cap": PROJECT_HINT_CAP,
                "global_reserve": GLOBAL_HINT_RESERVE,
                "protected_decisions": 0,
                "skipped": "unreadable_hint_store",
            }
        maintainers: dict[str, dict[str, Any]] = {}
        generated: dict[str, dict[str, Any]] = {}
        for hint in _list(_dict(existing).get("hints"))[
            : legion_learning_context.MAX_HINTS
            + legion_learning_context.MAX_EXCLUDED_HINTS
        ]:
            if not isinstance(hint, dict):
                continue
            hint_id = _text(hint.get("id"))
            if not hint_id:
                continue
            bucket = generated if hint.get("origin") == "self-learn-memory" else maintainers
            bucket.setdefault(hint_id, hint)

        lifecycle = _dict(report.get("learning_laws"))
        if "learning_laws" in report:
            for hint_id, hint in list(generated.items()):
                law_key = _text(hint.get("law_key"))
                if law_key and lifecycle.get(law_key) != "active":
                    retired = dict(hint)
                    if _text(retired.get("status")) == "active":
                        retired["status"] = "retired"
                        retired["lifecycle_owner"] = "learning-law"
                    generated[hint_id] = retired

        outcomes = {
            _text(item.get("id")): item
            for item in _list(report.get("outcomes"))
            if isinstance(item, dict) and _text(item.get("id"))
        }
        incoming: dict[str, dict[str, Any]] = {}
        for proposal in _list(report.get("proposals")):
            if not isinstance(proposal, dict):
                continue
            outcome = outcomes.get(_text(proposal.get("outcome_id")), {})
            hint = _typed_hint_from_proposal(proposal, outcome)
            if hint is None:
                continue
            prior = generated.get(hint["id"])
            # A maintainer may explicitly retire or supersede a generated ID.
            # Never reactivate that terminal decision during the next scan.
            if (
                prior
                and _text(prior.get("status")) in {"retired", "superseded"}
                and prior.get("lifecycle_owner") != "learning-law"
            ):
                incoming[hint["id"]] = prior
            else:
                incoming[hint["id"]] = hint
        generated.update(incoming)

        protected_decisions = {
            hint_id: hint
            for hint_id, hint in generated.items()
            if _text(hint.get("status")) in {"retired", "superseded"}
            and hint.get("lifecycle_owner") != "learning-law"
        }
        evictable_generated = {
            hint_id: hint
            for hint_id, hint in generated.items()
            if hint_id not in protected_decisions
        }
        status_rank = {"active": 0, "superseded": 1, "retired": 2}
        scope_rank = {"exact": 0, "selector": 1, "global": 2}
        ordered_maintainers = list(maintainers.values())
        ordered_generated = sorted(
            evictable_generated.values(),
            key=lambda hint: (
                status_rank.get(_text(hint.get("status")), 3),
                scope_rank.get(_text(hint.get("scope")), 3),
                _text(hint.get("id")),
            ),
        )
        ordered_decisions = [
            protected_decisions[hint_id] for hint_id in sorted(protected_decisions)
        ]
        storage_cap = (
            legion_learning_context.MAX_HINTS
            + legion_learning_context.MAX_EXCLUDED_HINTS
        )
        # Maintainer terminal decisions are durable tombstones. Keep them
        # outside the active/evictable slice, append them after compiler-visible
        # entries, and reduce active capacity rather than ever dropping one.
        available = min(
            max(0, PROJECT_HINT_CAP - len(ordered_maintainers)),
            max(
                0,
                storage_cap - len(ordered_maintainers) - len(ordered_decisions),
            ),
        )
        kept_generated = ordered_generated[:available]
        kept_ids = {
            _text(hint.get("id"))
            for hint in kept_generated + ordered_decisions
        }
        rejected_ids = sorted(
            hint_id
            for hint_id, hint in incoming.items()
            if hint_id not in kept_ids or _text(hint.get("status")) != "active"
        )
        payload = {
            "schema": "legion.learning-hints.v1",
            "hints": ordered_maintainers + kept_generated + ordered_decisions,
        }
        _write_json(path, payload)
        promoted = sum(
            1
            for hint_id, hint in incoming.items()
            if hint_id in kept_ids and _text(hint.get("status")) == "active"
        )
    return {
        "path": path,
        "promoted": promoted,
        "rejected": len(rejected_ids),
        "rejected_ids": rejected_ids,
        "total": len(payload["hints"]),
        "project_cap": PROJECT_HINT_CAP,
        "global_reserve": GLOBAL_HINT_RESERVE,
        "protected_decisions": len(ordered_decisions),
    }


def apply_memory(
    report: dict[str, Any],
    log_root: str,
    *,
    project_learning_dir: str = "",
) -> dict[str, Any]:
    _ensure_dir(self_learn_dir(log_root))
    lock_path = memory_path(log_root) + ".lock"
    with open(lock_path, "a+", encoding="utf-8") as lock, legion_file_lock.exclusive_lock(lock):
        return _apply_memory_locked(
            report,
            log_root,
            project_learning_dir=project_learning_dir,
        )


def _apply_memory_locked(
    report: dict[str, Any],
    log_root: str,
    *,
    project_learning_dir: str = "",
) -> dict[str, Any]:
    memory = load_memory(log_root)
    if not isinstance(memory.get("entities"), dict):
        memory["entities"] = {}
    entities = memory["entities"]
    for proposal in _list(report.get("proposals")):
        key = f"{proposal.get('target_type')}:{proposal.get('target_name')}"
        entry = _dict(entities.setdefault(key, {}))
        entry.setdefault("target_type", proposal.get("target_type"))
        entry.setdefault("target_name", proposal.get("target_name"))
        entry["updated_at"] = report.get("generated_at")
        entry.setdefault("proposal_ids", [])
        entry.setdefault("hints", [])
        entry.setdefault("source_paths", [])
        if proposal.get("id") not in entry["proposal_ids"]:
            entry["proposal_ids"].append(proposal.get("id"))
        hint = _hint_from_proposal(proposal)
        law_key = _text(proposal.get("law_key"))
        if law_key:
            marker = f"learning law '{law_key}'"
            entry["hints"] = [
                existing_hint
                for existing_hint in _list(entry.get("hints"))
                if marker not in _text(existing_hint).lower()
            ]
        if hint and hint not in entry["hints"]:
            entry["hints"].append(hint)
        if proposal.get("source_path") and proposal.get("source_path") not in entry["source_paths"]:
            entry["source_paths"].append(proposal.get("source_path"))
        entry["severity"] = max(
            [proposal.get("severity"), entry.get("severity", "info")],
            key=lambda value: SEVERITY_ORDER[_severity(value, "info")],
        )

    processed = _list(memory.setdefault("processed_outcome_ids", []))
    processed_set = set(processed)
    for outcome in _list(report.get("outcomes")):
        oid = _text(outcome.get("id"))
        if oid and oid not in processed_set:
            processed.append(oid)
            processed_set.add(oid)
    report_cursor = report.get("input_cursor")
    if isinstance(report_cursor, dict):
        # A report is derived from a specific cursor snapshot. If another
        # learner advanced memory after the report was built, keep the newer
        # cursor and its matching aggregate. The next incremental run will
        # consume any bytes unique to the stale report without replaying old
        # history.
        base_cursor = report.get("input_cursor_base")
        current_cursor = _dict(memory.get("input_cursor"))
        cursor_is_current = (
            isinstance(base_cursor, dict) and current_cursor == base_cursor
        )
        if cursor_is_current:
            memory["input_cursor"] = report_cursor
            if isinstance(report.get("trace_contrast"), dict):
                memory["trace_contrast"] = report["trace_contrast"]
    elif isinstance(report.get("trace_contrast"), dict):
        memory["trace_contrast"] = report["trace_contrast"]

    reports = _list(memory.setdefault("reports", []))
    report_ref = {
        "generated_at": report.get("generated_at"),
        "outcomes": len(_list(report.get("outcomes"))),
        "proposals": len(_list(report.get("proposals"))),
        "path": daily_report_path(log_root, _text(report.get("day")) or None),
    }
    if report_ref not in reports:
        reports.append(report_ref)
    memory["updated_at"] = report.get("generated_at")
    typed_hints = sync_typed_hints(
        report,
        project_learning_dir
        or os.path.join(os.path.expanduser(log_root), "learning"),
    )
    memory["typed_hints"] = typed_hints
    _write_json(memory_path(log_root), memory)
    append_experiment_log(report, log_root)
    return memory


def append_experiment_log(report: dict[str, Any], log_root: str) -> None:
    path = experiments_path(log_root)
    _ensure_dir(os.path.dirname(path))
    exists = os.path.exists(path)
    with open(path, "a", encoding="utf-8") as handle:
        if not exists:
            handle.write("# Legion Self-Learning Experiments\n\n")
            handle.write(
                "Daily loop: observe spans/evals/review findings -> analyze failures -> "
                "write proposals and memory -> validate through legion-improve.\n\n"
            )
        handle.write(f"## {_text(report.get('day')) or _date_utc()} - daily loop\n\n")
        handle.write(f"- Outcomes: {len(_list(report.get('outcomes')))}\n")
        handle.write(f"- Proposals: {len(_list(report.get('proposals')))}\n")
        handle.write(f"- Spans scanned: {report.get('spans')}\n")
        scorecard = _dict(report.get("scorecard"))
        metrics = _dict(scorecard.get("metrics"))
        if scorecard:
            if _scorecard_unmeasured(scorecard):
                handle.write(
                    "- Baseline score: unmeasured "
                    f"({_text(scorecard.get('reason'))}; "
                    f"doctor={'ok' if _doctor_ok(scorecard) else 'fail'})\n"
                )
            else:
                handle.write(
                    "- Baseline score: "
                    f"{scorecard.get('score', 0)} "
                    f"(P@1={metrics.get('precision_at_1', 0)}, "
                    f"hit@k={metrics.get('hit_at_k', 0)}, "
                    f"doctor={'ok' if _doctor_ok(scorecard) else 'fail'})\n"
                )
        top = sorted(
            _dict(report.get("by_entity")).items(),
            key=lambda item: (-item[1], item[0]),
        )[:8]
        if top:
            handle.write("- Top entities: " + ", ".join(f"{k}={v}" for k, v in top) + "\n")
        handle.write("\n")
    append_experiment_ledger(report, log_root)


def _git_commit(repo: str) -> str:
    try:
        proc = subprocess.run(
            ["git", "-C", repo, "rev-parse", "--short", "HEAD"],
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            timeout=5,
        )
    except (OSError, subprocess.TimeoutExpired):
        return ""
    return proc.stdout.strip() if proc.returncode == 0 else ""


def _tsv(value: Any) -> str:
    return str(value if value is not None else "").replace("\t", " ").replace("\n", " ")


def _doctor_ok(scorecard: dict[str, Any]) -> bool:
    return any(
        check.get("name") == "legion-doctor" and bool(check.get("ok"))
        for check in _list(scorecard.get("checks"))
    )


def _scorecard_unmeasured(scorecard: dict[str, Any]) -> bool:
    return _text(scorecard.get("measurement")) == "unmeasured"


def _ledger_score_fields(scorecard: dict[str, Any]) -> list[Any]:
    metrics = _dict(scorecard.get("metrics"))
    if _scorecard_unmeasured(scorecard):
        return ["", "", "", "", "", "", "1" if _doctor_ok(scorecard) else "0"]
    return [
        metrics.get("cases", 0),
        metrics.get("pass", 0),
        metrics.get("miss", 0),
        metrics.get("collision", 0),
        metrics.get("precision_at_1", 0),
        metrics.get("hit_at_k", 0),
        "1" if _doctor_ok(scorecard) else "0",
    ]


def append_experiment_ledger(report: dict[str, Any], log_root: str) -> None:
    """Append a compact daily scorecard row, inspired by autoresearch results.tsv."""
    path = experiment_ledger_path(log_root)
    _ensure_dir(os.path.dirname(path))
    exists = os.path.exists(path)
    outcomes = len(_list(report.get("outcomes")))
    proposals = len(_list(report.get("proposals")))
    unmeasured = _scorecard_unmeasured(_dict(report.get("scorecard")))
    status = "unmeasured" if unmeasured else ("clean" if outcomes == 0 else "proposal")
    description = f"{outcomes} outcome(s), {proposals} proposal(s), {report.get('spans', 0)} span(s)"
    baseline = _dict(report.get("scorecard"))
    if unmeasured:
        description = f"unmeasured scorecard: {_text(baseline.get('reason'))}; {description}"
    rows = [[
        _text(report.get("day")) or _date_utc(),
        _git_commit(_text(report.get("repo"))),
        "baseline",
        "",
        "",
        report.get("spans", 0),
        outcomes,
        proposals,
        *_ledger_score_fields(baseline),
        "" if unmeasured else baseline.get("score", 0),
        "",
        0,
        status,
        "report-only",
        description,
    ]]
    with open(path, "a", encoding="utf-8") as handle:
        if not exists:
            handle.write(
                "date\tcommit\texperiment_id\tcandidate_id\ttarget\tspans\toutcomes\t"
                "proposals\teval_cases\teval_pass\teval_miss\teval_collision\t"
                "precision_at_1\thit_at_k\tdoctor_ok\tbaseline_score\tcandidate_score\t"
                "delta\tstatus\tdecision\tdescription\n"
            )
        for row in rows:
            handle.write("\t".join(_tsv(item) for item in row) + "\n")


def _path_in_repo(path: str, repo: str) -> bool:
    try:
        repo_real = os.path.realpath(repo)
        return os.path.commonpath([os.path.realpath(path), repo_real]) == repo_real
    except ValueError:
        return False


def _path_uses_symlink(path: str, repo: str) -> bool:
    if not _path_in_repo(path, repo):
        return False
    repo_abs = os.path.abspath(repo)
    path_abs = os.path.abspath(path)
    try:
        rel = os.path.relpath(path_abs, repo_abs)
    except ValueError:
        return True
    if rel.startswith(".." + os.sep) or rel == "..":
        return True
    current = repo_abs
    for part in rel.split(os.sep):
        if not part or part == ".":
            continue
        current = os.path.join(current, part)
        if os.path.islink(current):
            return True
    return False


def hints(log_root: str, entity: str | None = None, limit: int = 20) -> dict[str, Any]:
    memory = load_memory(log_root)
    entries = _dict(memory.get("entities"))
    if entity:
        entries = {entity: entries.get(entity, {})} if entity in entries else {}
    sorted_entries = sorted(
        entries.items(),
        key=lambda item: (
            -SEVERITY_ORDER[_severity(_dict(item[1]).get("severity"), "info")],
            item[0],
        ),
    )[:limit]
    return {
        "schema": "legion.self-learning.hints.v1",
        "updated_at": memory.get("updated_at"),
        "entities": {key: value for key, value in sorted_entries if value},
    }


def render_hints(payload: dict[str, Any]) -> str:
    entities = _dict(payload.get("entities"))
    if not entities:
        return "No Legion self-learning hints yet."
    lines = [f"Legion self-learning hints (updated {payload.get('updated_at')})"]
    for key, entry in entities.items():
        lines.append(f"\n{key} [{entry.get('severity', 'info')}]")
        for hint in list(reversed(_list(entry.get("hints"))))[:5]:
            lines.append(f"- {hint}")
    return "\n".join(lines)


def record_manual_outcome(args: argparse.Namespace) -> dict[str, Any]:
    if ":" in args.entity:
        target_type, target_name = args.entity.split(":", 1)
    else:
        target_type, target_name = "plugin", args.entity
    outcome = _outcome(
        source="manual",
        target_type=target_type,
        target_name=target_name,
        severity=args.severity,
        summary=args.summary,
        evidence=args.evidence or args.source or "",
        source_path=args.source or "",
    )
    _append_jsonl(outcomes_path(args.logs), outcome)
    return outcome


def run_command(args: argparse.Namespace) -> int:
    # Kept solely so old automation gets a clear, safe migration response.
    # In particular, it must not re-enable the historical path that eventually
    # copied a candidate back into the operator checkout.
    if args.apply_source:
        payload = {
            "status": "compatibility_dry_run",
            "source_mutation": False,
            "message": "--apply-source is compatibility-only; submit an eligible typed proposal to legion-improve run --mode dry-run or --mode draft.",
        }
        print(json.dumps(payload, indent=2, sort_keys=True) if args.json else payload["message"])
        return 2
    day = args.day or _date_utc()
    report = build_report(
        args.repo,
        args.logs,
        day,
        scan_all=not bool(args.day),
        include_processed=args.include_processed,
        telemetry_dir=getattr(args, "telemetry_dir", ""),
    )
    report_path = daily_report_path(args.logs, day)

    _write_json(report_path, report)
    improvement_queue = write_improvement_queue(report, args.logs)

    memory = None
    if args.apply_memory:
        state = legion_state.resolve_state(args.repo)
        memory = apply_memory(
            report,
            args.logs,
            project_learning_dir=state["project_learning_dir"],
        )

    payload = {
        "report_path": report_path,
        "memory_path": memory_path(args.logs),
        "hints_path": _text(
            _dict(_dict(memory or {}).get("typed_hints")).get("path")
        ),
        "typed_hints": _dict(_dict(memory or {}).get("typed_hints")),
        "applied_memory": memory is not None,
        "changed_source": [],
        "experiments": None,
        "improvement_queue": improvement_queue,
        "scorecard": report.get("scorecard"),
        "span_sources": report.get("span_sources"),
        "summary": {
            "spans": report["spans"],
            "span_stores": _dict(report.get("span_sources")).get(
                "contributing_stores", 0
            ),
            "catalog_entities": report["catalog_entities"],
            "outcomes": len(report["outcomes"]),
            "proposals": len(report["proposals"]),
            "improvement_proposals": len(report["improvement_proposals"]),
        },
        "by_entity": report["by_entity"],
    }
    if args.json:
        print(json.dumps(payload, indent=2, sort_keys=True))
    elif not args.quiet:
        print(
            "legion-self-learn: "
            f"{payload['summary']['outcomes']} outcomes, "
            f"{payload['summary']['proposals']} proposals, "
            f"memory={'applied' if payload['applied_memory'] else 'report-only'}"
        )
        print(f"report: {payload['report_path']}")
        if payload["applied_memory"]:
            print(f"memory: {payload['memory_path']}")
            print(
                "typed hints: "
                f"promoted={payload['typed_hints'].get('promoted', 0)} "
                f"rejected={payload['typed_hints'].get('rejected', 0)}"
            )
    return 0


def compile_context_command(args: argparse.Namespace) -> int:
    state = legion_state.resolve_state(args.repo)
    payload = legion_learning_context.compile_context(
        repository_identity=state["repository_identity"],
        entity=args.entity,
        stage=args.stage,
        hint_directories=learning_hint_directories(state),
        max_hints=args.max_hints,
        max_tokens=args.max_tokens,
    )
    print(json.dumps(payload, indent=2, sort_keys=True))
    return 0


def learning_hint_directories(state: dict[str, str]) -> list[str]:
    """Return clone-independent memory plus bounded legacy compatibility.

    The path-local directory is retained as a read-only fallback so an upgrade
    can consume hints produced before repository-stable learning storage without
    copying or deleting operator state. Duplicate IDs prefer the stable store.
    """
    directories = [state["project_learning_dir"]]
    legacy = state.get("path_project_learning_dir", "")
    if legacy and legacy not in directories:
        directories.append(legacy)
    global_learning = state["global_learning_dir"]
    if global_learning not in directories:
        directories.append(global_learning)
    return directories


def typed_hints_for_humans(
    state: dict[str, str], entity: str | None, limit: int
) -> dict[str, Any]:
    """Render trusted typed memory through the legacy human hints surface."""
    now = datetime.now(timezone.utc)
    requested = _text(entity)
    grouped: dict[str, list[str]] = {}
    seen: set[tuple[str, str]] = set()
    for hint in legion_learning_context.load_hints(learning_hint_directories(state)):
        if hint.get("trusted") is not True or _text(hint.get("status")) != "active":
            continue
        if legion_learning_context._expired(hint, now):
            continue
        scope = _text(hint.get("scope"))
        target = _text(hint.get("entity"))
        if scope == "exact" and requested and target != requested:
            continue
        if scope not in {"exact", "global"}:
            continue
        guidance = _text(hint.get("guidance"))
        if not guidance:
            continue
        display_target = requested or target or "global:*"
        key = (display_target, " ".join(guidance.split()).casefold())
        if key in seen:
            continue
        seen.add(key)
        grouped.setdefault(display_target, []).append(guidance)
        if sum(len(values) for values in grouped.values()) >= limit:
            break
    return {
        "schema": "legion.self-learning.hints.v1",
        "updated_at": _date_utc(),
        "entities": {
            key: {"severity": "info", "hints": values}
            for key, values in sorted(grouped.items())
        },
    }


def merge_human_hints(*payloads: dict[str, Any], limit: int) -> dict[str, Any]:
    """Merge legacy and typed displays without duplicating guidance text."""
    merged: dict[str, dict[str, Any]] = {}
    count = 0
    updated_at = None
    for payload in payloads:
        updated_at = payload.get("updated_at") or updated_at
        for entity, raw_entry in _dict(payload.get("entities")).items():
            if count >= limit:
                break
            entry = _dict(raw_entry)
            if entity not in merged:
                # The legacy memory surface includes provenance fields such as
                # target_type/target_name that downstream benchmark and UI
                # consumers still use. Preserve those fields while replacing
                # only the hint list with the de-duplicated merged sequence.
                target = dict(entry)
                target["severity"] = _text(entry.get("severity")) or "info"
                target["hints"] = []
                merged[entity] = target
            else:
                target = merged[entity]
                for key, value in entry.items():
                    if key != "hints" and key not in target:
                        target[key] = value
            existing = {
                " ".join(_text(item).split()).casefold()
                for item in _list(target.get("hints"))
            }
            for guidance in _list(entry.get("hints")):
                guidance = _text(guidance)
                key = " ".join(guidance.split()).casefold()
                if not guidance or key in existing:
                    continue
                target["hints"].append(guidance)
                existing.add(key)
                count += 1
                if count >= limit:
                    break
    return {
        "schema": "legion.self-learning.hints.v1",
        "updated_at": updated_at,
        "entities": merged,
    }


def reconcile_command(args: argparse.Namespace) -> int:
    state = legion_state.resolve_state(args.repo)
    payload = legion_learning_context.reconcile_state(
        repository_identity=state["repository_identity"],
        state_path=os.path.join(state["project_learning_dir"], "state.json"),
        legacy_state_path=args.legacy_state,
        evidence_path=args.evidence,
    )
    print(json.dumps(payload, indent=2, sort_keys=True))
    return 0


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(prog="legion-self-learn")
    sub = parser.add_subparsers(dest="cmd")

    run = sub.add_parser("run", help="mine outcomes and write daily proposals")
    run.add_argument("--repo", default=default_repo())
    run.add_argument("--logs", default=DEFAULT_LOG_ROOT)
    run.add_argument("--day", default="", help="UTC day to score (YYYY-MM-DD, default today)")
    run.add_argument("--apply-memory", action="store_true")
    run.add_argument("--apply-source", action="store_true")
    run.add_argument("--include-processed", action="store_true")
    run.add_argument("--json", action="store_true")
    run.add_argument("--quiet", action="store_true")

    hp = sub.add_parser("hints", help="print active self-learning memory")
    hp.add_argument("--repo", default=os.getcwd())
    hp.add_argument("--logs", default=DEFAULT_LOG_ROOT)
    hp.add_argument("--entity")
    hp.add_argument("--limit", type=int, default=20)
    hp.add_argument("--json", action="store_true")

    rec = sub.add_parser("record", help="record a bug/failure found by a session")
    rec.add_argument("--logs", default=DEFAULT_LOG_ROOT)
    rec.add_argument("--entity", required=True, help="TYPE:NAME, e.g. command:feature")
    rec.add_argument("--summary", required=True)
    rec.add_argument("--severity", default="medium", choices=sorted(SEVERITY_ORDER))
    rec.add_argument("--source", default="")
    rec.add_argument("--evidence", default="")
    rec.add_argument("--json", action="store_true")

    context = sub.add_parser("compile-context", help="compile trusted typed learning guidance")
    context.add_argument("--repo", default=default_repo())
    context.add_argument("--entity", required=True, help="TYPE:NAME target receiving guidance")
    context.add_argument("--stage", required=True, help="lifecycle stage receiving guidance")
    context.add_argument("--max-hints", type=int, default=20)
    context.add_argument("--max-tokens", type=int, default=1200)
    context.add_argument("--json", action="store_true", help="reserved for CLI compatibility; output is JSON")

    reconcile = sub.add_parser("reconcile", help="rehome compatible legacy learning state")
    reconcile.add_argument("--repo", default=default_repo())
    reconcile.add_argument("--legacy-state", default="")
    reconcile.add_argument("--evidence", default="")
    reconcile.add_argument("--json", action="store_true", help="reserved for CLI compatibility; output is JSON")

    args = parser.parse_args(argv)
    if args.cmd is None:
        args = parser.parse_args(["run", *(argv or [])])
    if hasattr(args, "logs") and not args.logs:
        repo_for_state = getattr(args, "repo", os.getcwd())
        resolved = legion_state.resolve_state(repo_for_state)
        args.logs = resolved["state_root"]
        args.telemetry_dir = resolved["telemetry_dir"]
    if args.cmd == "run":
        return run_command(args)
    if args.cmd == "hints":
        state = legion_state.resolve_state(args.repo)
        payload = merge_human_hints(
            hints(args.logs, args.entity, args.limit),
            typed_hints_for_humans(state, args.entity, args.limit),
            limit=args.limit,
        )
        if args.json:
            print(json.dumps(payload, indent=2, sort_keys=True))
        else:
            print(render_hints(payload))
        return 0
    if args.cmd == "record":
        outcome = record_manual_outcome(args)
        if args.json:
            print(json.dumps(outcome, indent=2, sort_keys=True))
        else:
            print(f"recorded {outcome['id']} -> {outcome['target_type']}:{outcome['target_name']}")
        return 0
    if args.cmd == "compile-context":
        return compile_context_command(args)
    if args.cmd == "reconcile":
        return reconcile_command(args)
    parser.print_help()
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
