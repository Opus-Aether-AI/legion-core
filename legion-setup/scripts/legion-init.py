#!/usr/bin/env python3
"""Add a precise, reversible Legion workflow policy to a repository.

Only marker-delimited blocks are managed. Existing content outside those blocks
is preserved exactly.
"""

from __future__ import annotations

import argparse
from contextlib import contextmanager, nullcontext
import difflib
import fcntl
import hashlib
import json
import os
from pathlib import Path
import re
import stat
import subprocess
import sys
import tempfile
from typing import Any


SCHEMA = "legion.init.v1"
POLICY_VERSION = "v1"
AGENTS_START = "<!-- legion:init:v1:agents:start -->"
AGENTS_END = "<!-- legion:init:v1:agents:end -->"
CLAUDE_START = "<!-- legion:init:v1:claude:start -->"
CLAUDE_END = "<!-- legion:init:v1:claude:end -->"

AGENTS_BODY = """\
## Legion workflow

Legion is the mandatory default operating mode for coding tasks in this
repository, regardless of which compatible harness is active. “Default” means
enter the appropriate Legion mode; it does not mean every tiny action must be
delegated.

- If `LEGION_ACTIVE=1`, `LEGION_DEPTH` is positive, or the working directory is
  under `.legion/worktrees/`, this process is already a delegated executor:
  implement the assigned slice directly and do not start another Legion
  workflow. Return to the parent if the slice needs re-planning.
- Otherwise, before editing, invoke the applicable installed Legion skill or
  command and read relevant `legion-self-learn hints`.
- When `.legion/legion-core.json` exists, its exact version and release commit
  are this repository's declared Legion baseline. Update that managed pin only
  through the Legion release workflow.
- Use `legion-run` for substantial or multi-stage work that needs an explicit
  plan, deterministic validation, independent review, and retained evidence.
- Use `legion-orchestrate` or `legion-fanout` for dependency-aware parallel
  slices; use `legion-delegate` for scoped delegation and independent review.
- Do not call raw `claude`, `codex`, `agent`, or `opencode` processes for
  delegated coding work. Go through Legion so isolation, routing, telemetry,
  and review contracts remain active.
- Inline work is allowed only when the active Legion harness-mode guidance
  selects it. It still follows this repository's tests and health gates.
- If Legion is unavailable or blocked, stop and report the blocker instead of
  silently bypassing it."""

CLAUDE_BODY = """\
## Legion workflow

Load and follow the shared Legion-first repository policy in `AGENTS.md`. Keep
shared guidance there; this file should contain only Claude-specific additions."""


class InitError(RuntimeError):
    pass


def _policy_hash(body: str) -> str:
    return hashlib.sha256(body.encode("utf-8")).hexdigest()[:16]


def _managed_hash(
    body: str,
    *,
    before: int,
    after: int,
    created: bool,
    newline: str,
) -> str:
    payload = json.dumps(
        {
            "after": after,
            "before": before,
            "body": body.replace("\r\n", "\n"),
            "created": created,
            "eol": "crlf" if newline == "\r\n" else "lf",
        },
        ensure_ascii=True,
        sort_keys=True,
        separators=(",", ":"),
    )
    return hashlib.sha256(payload.encode("utf-8")).hexdigest()[:16]


def _metadata_line(
    *,
    before: int,
    after: int,
    created: bool,
    body: str,
    newline: str,
) -> str:
    eol = "crlf" if newline == "\r\n" else "lf"
    return (
        f"<!-- legion:init:{POLICY_VERSION}:padding-before={before};"
        f"padding-after={after};created={int(created)};eol={eol};"
        f"sha256={_managed_hash(body, before=before, after=after, created=created, newline=newline)} -->"
    )


def _render_block(
    start: str,
    end: str,
    body: str,
    *,
    before: int,
    after: int,
    created: bool,
    newline: str,
    metadata_newline: str | None = None,
) -> str:
    metadata = _metadata_line(
        before=before,
        after=after,
        created=created,
        body=body,
        newline=metadata_newline or newline,
    )
    rendered_body = body.replace("\n", newline)
    return newline.join((start, metadata, rendered_body, end))


def _managed_range(text: str, start: str, end: str) -> tuple[int, int] | None:
    starts = [match.start() for match in re.finditer(re.escape(start), text)]
    ends = [match.end() for match in re.finditer(re.escape(end), text)]
    tokens = [match.start() for match in re.finditer(r"<!-- legion:init:", text)]
    if not starts and not ends:
        if tokens:
            raise InitError("unsupported or mismatched legion-init marker found")
        return None
    if len(starts) != 1 or len(ends) != 1 or starts[0] >= ends[0]:
        raise InitError(f"malformed managed block: expected one ordered {start} / {end} pair")
    if len(tokens) != 3 or any(position < starts[0] or position >= ends[0] for position in tokens):
        raise InitError("nested, duplicate, or mismatched legion-init marker found")
    return starts[0], ends[0]


def _block_metadata(
    text: str,
    start: str,
    end: str,
    *,
    require_integrity: bool = False,
) -> tuple[int, int, bool, str, bool]:
    span = _managed_range(text, start, end)
    if span is None:
        raise InitError("managed block metadata requested for an absent block")
    block = text[span[0] : span[1]]
    pattern = re.compile(
        re.escape(start)
        + r"\r?\n<!-- legion:init:v1:padding-before=(\d+);"
        + r"padding-after=(\d+);created=([01]);"
        + r"(?:eol=(lf|crlf);)?sha256=([0-9a-f]{16}) -->\r?\n"
    )
    match = pattern.match(block)
    if match is None:
        raise InitError("managed block is missing valid legion-init v1 metadata")
    current_newline = "\r\n" if block.startswith(start + "\r\n") else "\n"
    stored_newline = "\r\n" if match.group(4) == "crlf" else "\n" if match.group(4) == "lf" else current_newline
    before = int(match.group(1))
    after = int(match.group(2))
    created = match.group(3) == "1"
    body_suffix = current_newline + end
    body = block[match.end() :]
    if not body.endswith(body_suffix):
        raise InitError("managed block body is malformed")
    body = body[: -len(body_suffix)]
    stored_hash = match.group(5)
    integrity_ok = stored_hash == _managed_hash(
        body,
        before=before,
        after=after,
        created=created,
        newline=stored_newline,
    )
    legacy_ok = stored_hash == _policy_hash(body.replace("\r\n", "\n"))
    if require_integrity and not integrity_ok:
        detail = "legacy metadata" if legacy_ok else "modified metadata or body"
        raise InitError(
            f"managed block integrity check failed ({detail}); "
            "run legion-init once to repair it before removal"
        )
    return before, after, created, stored_newline, integrity_ok


def _translated_padding(count: int, stored_newline: str, current_newline: str) -> int:
    if count % len(stored_newline) != 0:
        raise InitError("managed block padding metadata is inconsistent")
    return count // len(stored_newline) * len(current_newline)


def _remove(text: str, start: str, end: str) -> tuple[str, bool]:
    span = _managed_range(text, start, end)
    if span is None:
        return text, False
    before_count, after_count, created, stored_newline, _ = _block_metadata(
        text, start, end, require_integrity=True
    )
    current_newline = "\r\n" if text[span[0] :].startswith(start + "\r\n") else "\n"
    before_count = _translated_padding(before_count, stored_newline, current_newline)
    after_count = _translated_padding(after_count, stored_newline, current_newline)
    before_start = span[0] - before_count
    after_end = span[1] + after_count
    if before_start < 0 or after_end > len(text):
        raise InitError("managed block padding extends beyond the file")
    padding = text[before_start : span[0]] + text[span[1] : after_end]
    if any(char not in "\r\n" for char in padding):
        raise InitError("managed block padding was modified; refusing lossy removal")
    desired = text[:before_start] + text[after_end:]
    return desired, created and not desired


def _has_agents_import(text: str) -> bool:
    text = re.sub(r"<!--.*?-->", "", text, flags=re.DOTALL)
    fence_char = ""
    fence_length = 0
    for line in text.splitlines():
        stripped = line.lstrip()
        fence = re.match(r"^(`{3,}|~{3,})", stripped)
        if fence_char:
            if fence and fence.group(1)[0] == fence_char and len(fence.group(1)) >= fence_length:
                fence_char = ""
                fence_length = 0
            continue
        if fence:
            fence_char = fence.group(1)[0]
            fence_length = len(fence.group(1))
            continue
        if not line.startswith(("    ", "\t")) and re.search(
            r"(?<![\w/])@(?:\./)?AGENTS\.md(?![\w./-])", line
        ):
            return True
    return False


def _claude_body(existing: str) -> str:
    span = _managed_range(existing, CLAUDE_START, CLAUDE_END)
    unmanaged = (
        existing[: span[0]] + existing[span[1] :]
        if span is not None
        else existing
    )
    has_agents_import = _has_agents_import(unmanaged)
    import_line = "" if has_agents_import else "@AGENTS.md\n\n"
    return f"{import_line}{CLAUDE_BODY}"


def _newline_for(text: str) -> str:
    return "\r\n" if text.count("\r\n") > text.count("\n") - text.count("\r\n") else "\n"


def _upsert(
    text: str,
    start: str,
    end: str,
    body: str,
    *,
    file_existed: bool,
    prepend_new: bool = False,
) -> str:
    span = _managed_range(text, start, end)
    if span is not None:
        before, after, created, stored_newline, _ = _block_metadata(text, start, end)
        newline = "\r\n" if text[span[0] :].startswith(start + "\r\n") else "\n"
        block = _render_block(
            start,
            end,
            body,
            before=before,
            after=after,
            created=created,
            newline=newline,
            metadata_newline=stored_newline,
        )
        return text[: span[0]] + block + text[span[1] :]
    newline = _newline_for(text)
    if prepend_new and text:
        suffix = "" if text.startswith(newline * 2) else newline if text.startswith(newline) else newline * 2
        block = _render_block(
            start,
            end,
            body,
            before=0,
            after=len(suffix),
            created=False,
            newline=newline,
        )
        return block + suffix + text
    if not text or text.endswith(newline * 2):
        prefix = ""
    elif text.endswith(newline):
        prefix = newline
    else:
        prefix = newline * 2
    suffix = newline
    block = _render_block(
        start,
        end,
        body,
        before=len(prefix),
        after=len(suffix),
        created=not file_existed,
        newline=newline,
    )
    return text + prefix + block + suffix


def _read(path: Path) -> str:
    if path.is_symlink():
        raise InitError(f"refusing to modify symlink: {path}")
    if path.exists() and not path.is_file():
        raise InitError(f"refusing to modify non-file: {path}")
    try:
        if not path.exists():
            return ""
        with path.open("r", encoding="utf-8", newline="") as handle:
            return handle.read()
    except (OSError, UnicodeError) as exc:
        raise InitError(f"could not read {path}: {exc}") from exc


def _atomic_write(path: Path, content: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    original_mode = stat.S_IMODE(path.stat().st_mode) if path.exists() else 0o644
    fd, temp_name = tempfile.mkstemp(prefix=f".{path.name}.legion-init-", dir=path.parent)
    try:
        with os.fdopen(fd, "w", encoding="utf-8", newline="") as handle:
            handle.write(content)
            handle.flush()
            os.fsync(handle.fileno())
        os.chmod(temp_name, original_mode)
        os.replace(temp_name, path)
    except BaseException:
        try:
            os.unlink(temp_name)
        except FileNotFoundError:
            pass
        raise


def _plan_file(path: Path, *, remove: bool, claude: bool = False) -> dict[str, Any]:
    current = _read(path)
    start, end = (CLAUDE_START, CLAUDE_END) if claude else (AGENTS_START, AGENTS_END)
    existed = path.exists()
    if remove:
        desired, delete_file = _remove(current, start, end)
    else:
        body = _claude_body(current) if claude else AGENTS_BODY
        desired = _upsert(
            current,
            start,
            end,
            body,
            file_existed=existed,
            prepend_new=True,
        )
        delete_file = False
    changed = desired != current
    if remove:
        status = "would_remove" if changed else "absent"
    else:
        status = "would_update" if existed and changed else "would_create" if changed else "current"
    return {
        "path": str(path),
        "exists": existed,
        "changed": changed,
        "status": status,
        "_current": current,
        "_desired": desired,
        "_delete": delete_file,
        "_mode": stat.S_IMODE(path.stat().st_mode) if existed else None,
    }


def _resolve_repo(requested: Path) -> Path:
    if not requested.is_dir():
        raise InitError(f"repository directory not found: {requested}")
    result = subprocess.run(
        ["git", "-C", str(requested), "rev-parse", "--show-toplevel"],
        check=False,
        stdout=subprocess.PIPE,
        stderr=subprocess.DEVNULL,
        text=True,
    )
    if result.returncode != 0 or not result.stdout.strip():
        raise InitError(f"not a Git repository: {requested}")
    return Path(result.stdout.strip()).resolve()


def _reject_case_collisions(repo: Path) -> None:
    targets = {"agents.md": "AGENTS.md", "claude.md": "CLAUDE.md"}
    for child in repo.iterdir():
        expected = targets.get(child.name.casefold())
        if expected is not None and child.name != expected:
            raise InitError(f"case-colliding instruction file: {child.name} conflicts with {expected}")


@contextmanager
def _repo_lock(repo: Path):
    result = subprocess.run(
        ["git", "-C", str(repo), "rev-parse", "--git-path", "legion-init.lock"],
        check=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
    )
    lock_path = Path(result.stdout.strip())
    if not lock_path.is_absolute():
        lock_path = repo / lock_path
    lock_path.parent.mkdir(parents=True, exist_ok=True)
    with lock_path.open("a+b") as handle:
        fcntl.flock(handle.fileno(), fcntl.LOCK_EX)
        try:
            yield
        finally:
            fcntl.flock(handle.fileno(), fcntl.LOCK_UN)


def _apply_transaction(files: list[dict[str, Any]], *, remove: bool) -> None:
    applied: list[dict[str, Any]] = []
    try:
        for item in files:
            if not item["changed"]:
                continue
            path = Path(item["path"])
            if item["_delete"]:
                path.unlink()
            else:
                _atomic_write(path, item["_desired"])
            applied.append(item)
            item["status"] = "removed" if remove else "updated"
    except BaseException as exc:
        rollback_errors = []
        for item in reversed(applied):
            path = Path(item["path"])
            try:
                if item["exists"]:
                    _atomic_write(path, item["_current"])
                    os.chmod(path, item["_mode"])
                elif path.exists():
                    path.unlink()
            except BaseException as rollback_exc:
                rollback_errors.append(f"{path}: {rollback_exc}")
        detail = f"; rollback errors: {', '.join(rollback_errors)}" if rollback_errors else ""
        raise InitError(f"transaction failed and was rolled back: {exc}{detail}") from exc


def _consistency_warnings(files: list[dict[str, Any]]) -> list[str]:
    claude = next(item for item in files if Path(item["path"]).name == "CLAUDE.md")
    current = claude["_current"]
    span = _managed_range(current, CLAUDE_START, CLAUDE_END)
    unmanaged = current[: span[0]] + current[span[1] :] if span is not None else current
    duplicate = re.search(r"(?im)^#{1,6}[ \t]+legion workflow[ \t]*$", unmanaged)
    if duplicate:
        return [
            "CLAUDE.md contains unmanaged shared Legion guidance; preserve it, "
            "but consolidate shared policy into AGENTS.md manually"
        ]
    return []


def _render_human(payload: dict[str, Any], previews: list[str]) -> None:
    mode = payload["mode"]
    for preview in previews:
        if preview:
            print(preview, end="" if preview.endswith("\n") else "\n")
    for item in payload["files"]:
        print(f"{item['status']}: {item['path']}")
    for warning in payload.get("warnings", []):
        print(f"warning: {warning}", file=sys.stderr)
    if mode == "check" and not payload["ok"]:
        print("legion-init: repository policy is missing or stale", file=sys.stderr)


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(
        prog="legion-init",
        description="Preserve repo instructions while managing a precise Legion-first policy block.",
    )
    parser.add_argument("--repo", default=".", help="repository root (default: current directory)")
    mode = parser.add_mutually_exclusive_group()
    mode.add_argument("--check", action="store_true", help="exit 1 when managed policy is missing or stale")
    mode.add_argument("--remove", action="store_true", help="remove only Legion-managed blocks")
    parser.add_argument("--dry-run", action="store_true", help="show changes without writing")
    parser.add_argument("--json", action="store_true", help="emit machine-readable status")
    args = parser.parse_args(argv)

    try:
        repo = _resolve_repo(Path(args.repo).expanduser().resolve())
        _reject_case_collisions(repo)
        lock = _repo_lock(repo) if not args.check and not args.dry_run else nullcontext()
        with lock:
            files = [
                _plan_file(repo / "AGENTS.md", remove=args.remove),
                _plan_file(repo / "CLAUDE.md", remove=args.remove, claude=True),
            ]
            warnings = _consistency_warnings(files)
            previews = [
                "".join(
                    difflib.unified_diff(
                        item["_current"].splitlines(keepends=True),
                        item["_desired"].splitlines(keepends=True),
                        fromfile=item["path"],
                        tofile=item["path"],
                    )
                )
                for item in files
                if item["changed"] and args.dry_run
            ]
            changed = any(item["changed"] for item in files)
            if not args.check and not args.dry_run:
                _apply_transaction(files, remove=args.remove)
            payload = {
                "schema": SCHEMA,
                "repo": str(repo),
                "mode": "check" if args.check else "remove" if args.remove else "dry-run" if args.dry_run else "apply",
                "ok": (not changed and not warnings) if args.check else True,
                "changed": changed,
                "warnings": warnings,
                "files": [{key: value for key, value in item.items() if not key.startswith("_")} for item in files],
            }
    except (InitError, OSError, subprocess.SubprocessError) as exc:
        repo_text = str(Path(args.repo).expanduser().resolve())
        payload = {"schema": SCHEMA, "repo": repo_text, "mode": "error", "ok": False, "error": str(exc)}
        if args.json:
            print(json.dumps(payload, sort_keys=True))
        else:
            print(f"legion-init: {exc}", file=sys.stderr)
        return 2

    if args.json:
        print(json.dumps(payload, indent=2, sort_keys=True))
    else:
        _render_human(payload, previews)
    return 0 if payload["ok"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
