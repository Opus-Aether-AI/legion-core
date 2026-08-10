#!/usr/bin/env python3
"""Shared executor-family lookup for Legion telemetry consumers."""

from __future__ import annotations

import os
import re

try:
    import tomllib
except ModuleNotFoundError:  # pragma: no cover - py<3.11
    tomllib = None


_FALLBACK_CODING_FAMILIES = frozenset({"claude", "codex", "cursor", "opencode"})
DEFAULT_EXECUTORS_FILE = os.path.abspath(
    os.path.join(
        os.path.dirname(__file__), "..", "..", "legion-router", "config", "executors.toml"
    )
)


def _fallback_table(path):
    """Read the registry fields needed here when tomllib is unavailable."""
    executors = {}
    current = None
    section = re.compile(r"\[(?:executors\.)?([A-Za-z0-9_-]+)\]")
    with open(path, encoding="utf-8") as fh:
        for raw_line in fh:
            line = raw_line.split("#", 1)[0].strip()
            match = section.fullmatch(line)
            if match:
                current = match.group(1)
                executors.setdefault(current, {})
                continue
            if current is None or "=" not in line:
                continue
            key, value = (part.strip() for part in line.split("=", 1))
            if key == "kind" and len(value) >= 2 and value[0] == value[-1] == '"':
                executors[current][key] = value[1:-1]
    return {"executors": executors}


def load_coding_executor_families(path=None):
    """Return registry executors that accept scoped coding work."""
    registry = os.path.expanduser(
        str(path or os.environ.get("LEGION_EXECUTORS_FILE") or DEFAULT_EXECUTORS_FILE)
    )
    try:
        if tomllib is None:
            table = _fallback_table(registry)
        else:
            with open(registry, "rb") as fh:
                table = tomllib.load(fh)
    except (OSError, ValueError):
        return _FALLBACK_CODING_FAMILIES

    # legion-route accepts both `[executors.codex]` and top-level `[codex]`
    # registries; telemetry must classify the same dispatchable families.
    executors = table.get("executors", table)
    families = {
        name
        for name, config in executors.items()
        if isinstance(name, str)
        and isinstance(config, dict)
        and "coding" in str(config.get("kind") or "").split()
    }
    return frozenset(families) if families else _FALLBACK_CODING_FAMILIES


CODING_EXECUTOR_FAMILIES = load_coding_executor_families()


def executor_family(executor, families=CODING_EXECUTOR_FAMILIES):
    """Map mode labels such as codex-review/resume to their registry family."""
    if not isinstance(executor, str) or not executor:
        return None
    if executor in families:
        return executor
    family = executor.split("-", 1)[0]
    return family if family in families else None


def is_delegated_executor(executor):
    return executor_family(executor) is not None
