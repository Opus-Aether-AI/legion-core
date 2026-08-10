"""Shared, bounded filesystem and JSONL primitives for session learning."""

from __future__ import annotations

import json
import os
from collections.abc import Iterator, Sequence
from pathlib import Path
from typing import Any


PRUNED_DIRECTORIES = {
    ".git",
    ".hg",
    ".svn",
    ".legion",
    ".codex-worktrees",
    ".venv",
    "venv",
    "node_modules",
    "__pycache__",
    ".pytest_cache",
    ".mypy_cache",
    ".ruff_cache",
    ".next",
    ".turbo",
    "dist",
    "build",
}


def walk_files(
    roots: Sequence[Path],
    *,
    suffixes: set[str] | None = None,
) -> Iterator[Path]:
    """Yield matching files without descending into generated/worktree trees."""
    for root in roots:
        root = Path(root)
        if not root.exists():
            continue
        for current, dirs, files in os.walk(root):
            current_path = Path(current)
            dirs[:] = sorted(
                name
                for name in dirs
                if name not in PRUNED_DIRECTORIES
                and not (current_path.name == ".claude" and name == "worktrees")
            )
            for name in sorted(files):
                path = Path(current) / name
                if suffixes is None or path.suffix in suffixes:
                    yield path


def iter_jsonl_objects(
    path: Path,
    *,
    max_lines: int = 0,
) -> Iterator[tuple[int, dict[str, Any]]]:
    """Stream object-valued JSONL records, ignoring malformed/non-object rows."""
    try:
        handle = Path(path).open(encoding="utf-8", errors="ignore")
    except OSError:
        return
    with handle:
        for index, line in enumerate(handle):
            if max_lines > 0 and index >= max_lines:
                break
            try:
                payload = json.loads(line)
            except (ValueError, TypeError):
                continue
            if isinstance(payload, dict):
                yield index, payload
