#!/usr/bin/env python3
"""Optional code-intelligence diagnostics for Legion.

The first slice deliberately uses repo-native diagnostic commands instead of
making an LSP server a hard runtime dependency. That keeps legion-core install
lightweight while giving orchestration/bench a stable artifact and span shape.
"""

from __future__ import annotations

import argparse
import json
import os
import re
import shutil
import subprocess
import sys
import time
from datetime import datetime, timezone
from typing import Any

try:
    import tomllib
except ModuleNotFoundError:  # pragma: no cover - Python 3.9/3.10 compatibility
    tomllib = None  # type: ignore[assignment]

sys.path.insert(0, os.path.join(
    os.path.dirname(os.path.abspath(__file__)), "..", "..", "legion-observability", "scripts"))
try:
    import legion_state  # noqa: E402
except ModuleNotFoundError:  # code-intel can ship without the observability plugin
    legion_state = None


RESULT_SCHEMA = "legion.code-intel.v1"
SPAN_SCHEMA = "legion.span.v1"
DEFAULT_TIMEOUT_SECONDS = 120
DEFAULT_MAX_PROJECTS = 50
SKIP_DIRS = {
    ".git",
    ".hg",
    ".svn",
    ".venv",
    "venv",
    "env",
    "__pycache__",
    "node_modules",
    "dist",
    "build",
    ".next",
    ".turbo",
    ".legion",
    ".claude",
    ".codex-worktrees",
}
TSC_SHARED_CONFIG_NAMES = {
    "tsconfig.base.json",
    "tsconfig.options.json",
    "tsconfig.shared.json",
}


def _iso_utc() -> str:
    return datetime.now(timezone.utc).isoformat().replace("+00:00", "Z")


def _date_utc() -> str:
    return datetime.now(timezone.utc).strftime("%Y-%m-%d")


def _run_id() -> str:
    return f"code-intel-{datetime.now(timezone.utc).strftime('%Y%m%d-%H%M%S')}-{os.getpid()}"


def _text(value: Any) -> str:
    return value.strip() if isinstance(value, str) else ""


def _repo_path(repo: str) -> str:
    path = os.path.realpath(os.path.abspath(os.path.expanduser(repo)))
    if not os.path.isdir(path):
        raise ValueError(f"repo is not a directory: {repo}")
    return path


def _rel(repo: str, path: str) -> str:
    if not path:
        return ""
    expanded = os.path.abspath(os.path.join(repo, path)) if not os.path.isabs(path) else path
    expanded = os.path.realpath(expanded)
    try:
        rel = os.path.relpath(expanded, repo)
    except ValueError:
        return path
    return rel.replace(os.path.sep, "/")


def _first_existing(paths: list[str]) -> str:
    for path in paths:
        if path and os.path.isfile(path) and os.access(path, os.X_OK):
            return path
    return ""


def _which(cmd: str) -> str:
    return shutil.which(cmd) or ""


def _has_file(repo: str, rel: str) -> bool:
    return os.path.isfile(os.path.join(repo, rel))


def _has_any_file(repo: str, suffixes: tuple[str, ...], limit: int = 1) -> bool:
    found = 0
    for root, dirs, files in os.walk(repo):
        dirs[:] = [d for d in dirs if d not in SKIP_DIRS]
        for name in files:
            if name.endswith(suffixes):
                found += 1
                if found >= limit:
                    return True
    return False


def _load_json(path: str) -> dict[str, Any]:
    try:
        with open(path, encoding="utf-8") as handle:
            data = json.load(handle)
    except (OSError, ValueError, TypeError):
        return {}
    return data if isinstance(data, dict) else {}


def _git_changed_files(repo: str, base: str) -> list[str]:
    changed: set[str] = set()
    try:
        proc = subprocess.run(
            ["git", "-C", repo, "diff", "--name-only", "--diff-filter=ACMRTUXB", base, "--"],
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            timeout=20,
        )
        if proc.returncode == 0:
            changed.update(
                line.strip().replace(os.path.sep, "/")
                for line in proc.stdout.splitlines()
                if line.strip()
            )
    except (OSError, subprocess.TimeoutExpired):
        pass
    try:
        proc = subprocess.run(
            ["git", "-C", repo, "ls-files", "--others", "--exclude-standard"],
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            timeout=20,
        )
        if proc.returncode == 0:
            changed.update(
                line.strip().replace(os.path.sep, "/")
                for line in proc.stdout.splitlines()
                if line.strip()
            )
    except (OSError, subprocess.TimeoutExpired):
        pass
    return sorted(changed)


def _changed_filter(diagnostic: dict[str, Any], changed: set[str]) -> bool:
    if not changed:
        return False
    file_name = _text(diagnostic.get("file"))
    return bool(file_name and file_name in changed)


def _command_result(
    argv: list[str],
    *,
    repo: str,
    timeout: float,
) -> dict[str, Any]:
    start = time.monotonic()
    try:
        proc = subprocess.run(
            argv,
            cwd=repo,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            timeout=timeout,
        )
        return {
            "returncode": proc.returncode,
            "stdout": proc.stdout,
            "stderr": proc.stderr,
            "duration_ms": int((time.monotonic() - start) * 1000),
            "timed_out": False,
        }
    except subprocess.TimeoutExpired as exc:
        return {
            "returncode": 124,
            "stdout": exc.stdout or "",
            "stderr": exc.stderr or "",
            "duration_ms": int((time.monotonic() - start) * 1000),
            "timed_out": True,
        }
    except OSError as exc:
        return {
            "returncode": 127,
            "stdout": "",
            "stderr": str(exc),
            "duration_ms": int((time.monotonic() - start) * 1000),
            "timed_out": False,
        }


def _local_typescript_bin(repo: str) -> str:
    return (
        os.environ.get("LEGION_TSC_BIN", "")
        or _first_existing(
            [
                os.path.join(repo, "node_modules", ".bin", "tsc"),
                os.path.join(repo, "node_modules", "typescript", "bin", "tsc"),
            ]
        )
        or _which("tsc")
    )


def _typescript_projects(repo: str) -> list[str]:
    """Find executable project configs, excluding conventional shared bases."""
    projects: list[str] = []
    for root, dirs, files in os.walk(repo):
        dirs[:] = sorted(d for d in dirs if d not in SKIP_DIRS)
        for name in sorted(files):
            if name in TSC_SHARED_CONFIG_NAMES:
                continue
            if name == "tsconfig.json" or (
                name.startswith("tsconfig.") and name.endswith(".json")
            ):
                projects.append(_rel(repo, os.path.join(root, name)))
    return projects


def _project_limit_error(
    adapter: str,
    projects: list[str],
    max_projects: int,
) -> dict[str, Any] | None:
    if max_projects <= 0 or len(projects) <= max_projects:
        return None
    return {
        "name": adapter,
        "status": "error",
        "projects": projects,
        "project_count": len(projects),
        "diagnostics": [],
        "parse_error": (
            f"configured project count {len(projects)} exceeds configured "
            f"limit {max_projects}"
        ),
    }


_TSC_DIAG_RE = re.compile(
    r"^(?P<file>.+?)\((?P<line>\d+),(?P<column>\d+)\):\s+"
    r"(?P<severity>error|warning)\s+(?P<code>TS\d+):\s+(?P<message>.*)$"
)


def _parse_tsc(repo: str, text: str) -> list[dict[str, Any]]:
    diagnostics: list[dict[str, Any]] = []
    for raw_line in text.splitlines():
        line = raw_line.strip()
        match = _TSC_DIAG_RE.match(line)
        if not match:
            continue
        item = match.groupdict()
        diagnostics.append(
            {
                "adapter": "typescript",
                "file": _rel(repo, item["file"]),
                "line": int(item["line"]),
                "column": int(item["column"]),
                "severity": item["severity"],
                "code": item["code"],
                "message": item["message"].strip(),
            }
        )
    return diagnostics


def _typescript_adapter(
    repo: str,
    timeout: int,
    *,
    explicit: bool = False,
    max_projects: int = DEFAULT_MAX_PROJECTS,
) -> dict[str, Any]:
    projects = _typescript_projects(repo)
    if not projects and not (
        explicit and _has_any_file(repo, (".ts", ".tsx"), limit=1)
    ):
        return {
            "name": "typescript",
            "status": "skipped",
            "reason": "no configured TypeScript projects",
        }
    limit_error = _project_limit_error("typescript", projects, max_projects)
    if limit_error:
        return limit_error
    tsc = _local_typescript_bin(repo)
    if not tsc:
        return {"name": "typescript", "status": "skipped", "reason": "tsc not found"}
    configured = projects or [""]
    commands: list[list[str]] = []
    results: list[dict[str, Any]] = []
    diagnostics: list[dict[str, Any]] = []
    status = "ok"
    parse_errors: list[str] = []
    deadline = time.monotonic() + max(0, timeout)
    for project in configured:
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            status = "error"
            parse_errors.append(
                f"adapter deadline exhausted before {project or '<loose-files>'}"
            )
            break
        argv = [tsc, "--noEmit", "--pretty", "false"]
        if project:
            argv.extend(["--project", project])
        result = _command_result(argv, repo=repo, timeout=remaining)
        commands.append(argv)
        results.append(result)
        parsed = _parse_tsc(repo, f"{result['stdout']}\n{result['stderr']}")
        diagnostics.extend(parsed)
        if result["timed_out"]:
            status = "error"
            parse_errors.append(f"{project or '<loose-files>'}: timed out")
            parse_errors.append("adapter deadline exhausted")
            break
        elif result["returncode"] != 0 and not parsed:
            status = "error"
            parse_errors.append(
                f"{project or '<loose-files>'}: tsc exited nonzero without parseable diagnostics"
            )
        elif result["returncode"] != 0 and status != "error":
            status = "failed"
    return {
        "name": "typescript",
        "status": status,
        "cmd": commands[0] if len(commands) == 1 else commands,
        "projects": projects,
        "returncode": max(
            (int(item["returncode"]) for item in results),
            default=124,
        ),
        "duration_ms": sum(int(item["duration_ms"]) for item in results),
        "diagnostics": diagnostics,
        "parse_error": "; ".join(parse_errors),
        "raw_stdout_tail": "\n".join(str(item["stdout"])[-2000:] for item in results)[-4000:],
        "raw_stderr_tail": "\n".join(str(item["stderr"])[-2000:] for item in results)[-4000:],
    }


def _local_pyright_bin(repo: str) -> str:
    return (
        os.environ.get("LEGION_PYRIGHT_BIN", "")
        or _first_existing([os.path.join(repo, "node_modules", ".bin", "pyright")])
        or _which("pyright")
    )


def _pyproject_configures_pyright(path: str) -> bool:
    if tomllib is None:
        try:
            with open(path, encoding="utf-8", errors="ignore") as handle:
                return any(
                    re.match(r"^\s*\[\s*tool\.pyright(?:\.|\s*\])", line)
                    for line in handle
                )
        except OSError:
            return False
    try:
        with open(path, "rb") as handle:
            payload = tomllib.load(handle)
    except (OSError, tomllib.TOMLDecodeError):
        return False
    tool = payload.get("tool") if isinstance(payload, dict) else None
    return isinstance(tool, dict) and isinstance(tool.get("pyright"), dict)


def _pyright_projects(repo: str) -> list[str]:
    """Find configured Pyright projects and return their config paths."""
    projects: list[str] = []
    for root, dirs, files in os.walk(repo):
        dirs[:] = sorted(d for d in dirs if d not in SKIP_DIRS)
        if "pyrightconfig.json" in files:
            projects.append(_rel(repo, os.path.join(root, "pyrightconfig.json")))
        elif "pyproject.toml" in files and _pyproject_configures_pyright(
            os.path.join(root, "pyproject.toml")
        ):
            projects.append(_rel(repo, os.path.join(root, "pyproject.toml")))
    return projects


def _parse_pyright(repo: str, stdout: str) -> list[dict[str, Any]]:
    payload = json.loads(stdout or "{}")
    raw_items = payload.get("generalDiagnostics")
    if not isinstance(raw_items, list):
        return []
    diagnostics: list[dict[str, Any]] = []
    for raw in raw_items:
        if not isinstance(raw, dict):
            continue
        rng = raw.get("range") if isinstance(raw.get("range"), dict) else {}
        start = rng.get("start") if isinstance(rng.get("start"), dict) else {}
        line = start.get("line")
        column = start.get("character")
        code = raw.get("rule") or raw.get("code") or ""
        diagnostics.append(
            {
                "adapter": "pyright",
                "file": _rel(repo, _text(raw.get("file"))),
                "line": int(line) + 1 if isinstance(line, int) else 0,
                "column": int(column) + 1 if isinstance(column, int) else 0,
                "severity": _text(raw.get("severity")) or "error",
                "code": _text(code),
                "message": _text(raw.get("message")),
            }
        )
    return diagnostics


def _pyright_adapter(
    repo: str,
    timeout: int,
    *,
    explicit: bool = False,
    max_projects: int = DEFAULT_MAX_PROJECTS,
) -> dict[str, Any]:
    projects = _pyright_projects(repo)
    if not projects and not (
        explicit and _has_any_file(repo, (".py",), limit=1)
    ):
        return {
            "name": "pyright",
            "status": "skipped",
            "reason": "no configured Python project",
        }
    limit_error = _project_limit_error("pyright", projects, max_projects)
    if limit_error:
        return limit_error
    pyright = _local_pyright_bin(repo)
    if not pyright:
        return {"name": "pyright", "status": "skipped", "reason": "pyright not found"}
    configured = projects or [""]
    commands: list[list[str]] = []
    results: list[dict[str, Any]] = []
    diagnostics: list[dict[str, Any]] = []
    status = "ok"
    parse_errors: list[str] = []
    deadline = time.monotonic() + max(0, timeout)
    for project in configured:
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            status = "error"
            parse_errors.append(
                f"adapter deadline exhausted before {project or '<loose-files>'}"
            )
            break
        argv = [pyright, "--outputjson"]
        if project:
            argv.extend(["--project", project])
        result = _command_result(argv, repo=repo, timeout=remaining)
        commands.append(argv)
        results.append(result)
        parsed: list[dict[str, Any]] = []
        try:
            parsed = _parse_pyright(repo, result["stdout"])
        except ValueError as exc:
            parse_errors.append(f"{project or '<loose-files>'}: {exc}")
            status = "error"
        diagnostics.extend(parsed)
        if result["timed_out"]:
            status = "error"
            parse_errors.append(f"{project or '<loose-files>'}: timed out")
            parse_errors.append("adapter deadline exhausted")
            break
        elif result["returncode"] != 0 and not parsed:
            status = "error"
            parse_errors.append(
                f"{project or '<loose-files>'}: pyright exited nonzero without diagnostics"
            )
        elif result["returncode"] != 0 and status != "error":
            status = "failed"
    return {
        "name": "pyright",
        "status": status,
        "cmd": commands[0] if len(commands) == 1 else commands,
        "projects": projects,
        "returncode": max(
            (int(item["returncode"]) for item in results),
            default=124,
        ),
        "duration_ms": sum(int(item["duration_ms"]) for item in results),
        "diagnostics": diagnostics,
        "parse_error": "; ".join(parse_errors),
        "raw_stdout_tail": "\n".join(str(item["stdout"])[-2000:] for item in results)[-4000:],
        "raw_stderr_tail": "\n".join(str(item["stderr"])[-2000:] for item in results)[-4000:],
    }


def _selected_adapters(name: str) -> list[str]:
    if name == "auto":
        return ["typescript", "pyright"]
    return [name]


def _run_adapter(
    name: str,
    repo: str,
    timeout: int,
    *,
    explicit: bool = False,
    max_projects: int = DEFAULT_MAX_PROJECTS,
) -> dict[str, Any]:
    if name == "typescript":
        return _typescript_adapter(
            repo,
            timeout,
            explicit=explicit,
            max_projects=max_projects,
        )
    if name == "pyright":
        return _pyright_adapter(
            repo,
            timeout,
            explicit=explicit,
            max_projects=max_projects,
        )
    return {"name": name, "status": "error", "reason": f"unknown adapter: {name}"}


def _summarize(diagnostics: list[dict[str, Any]], adapters: list[dict[str, Any]]) -> dict[str, Any]:
    errors = sum(1 for item in diagnostics if _text(item.get("severity")).lower() == "error")
    warnings = sum(1 for item in diagnostics if _text(item.get("severity")).lower() == "warning")
    return {
        "diagnostics": len(diagnostics),
        "errors": errors,
        "warnings": warnings,
        "adapters_run": sum(1 for item in adapters if item.get("status") in {"ok", "failed", "error"}),
        "adapters_skipped": sum(1 for item in adapters if item.get("status") == "skipped"),
        "adapter_errors": sum(1 for item in adapters if item.get("status") == "error"),
    }


def _overall_status(summary: dict[str, Any], adapters: list[dict[str, Any]]) -> str:
    if summary["adapter_errors"]:
        return "error"
    if summary["errors"]:
        return "failed"
    if summary["adapters_run"] == 0:
        return "skipped"
    return "ok"


def _exit_code(status: str) -> int:
    if status == "failed":
        return 1
    if status == "error":
        return 2
    return 0


def _emit_span(payload: dict[str, Any], telemetry_dir: str) -> str:
    telemetry_root = os.path.abspath(os.path.expanduser(telemetry_dir))
    os.makedirs(telemetry_root, exist_ok=True)
    span_path = os.path.join(telemetry_root, f"{_date_utc()}.jsonl")
    trace_id = os.environ.get("LEGION_TRACE_ID") or payload["run_id"]
    parent_id = os.environ.get("LEGION_PARENT_ID") or ""
    status = payload["status"]
    if status == "skipped":
        span_status = "ok"
    elif status in {"ok", "failed", "error"}:
        span_status = status
    else:
        span_status = "error"
    span = {
        "schema": SPAN_SCHEMA,
        "ts": _iso_utc(),
        "run_id": payload["run_id"],
        "trace_id": trace_id,
        "parent_id": parent_id or None,
        "executor": "legion-code-intel",
        "model": "offline-diagnostics",
        "archetype": "code-intelligence",
        "task": "code-intel diagnostics",
        "status": span_status,
        "target_type": os.environ.get("LEGION_TARGET_TYPE") or None,
        "target_name": os.environ.get("LEGION_TARGET_NAME") or None,
        "duration_ms": payload["duration_ms"],
        "cost_usd": 0,
        "tokens": {},
        "artifacts": {
            "schema": payload["schema"],
            "status": payload["status"],
            "adapter": payload["adapter"],
            "changed_only": payload["changed_only"],
            "diagnostics": payload["summary"]["diagnostics"],
            "errors": payload["summary"]["errors"],
            "warnings": payload["summary"]["warnings"],
        },
    }
    with open(span_path, "a", encoding="utf-8") as handle:
        handle.write(json.dumps(span, sort_keys=True))
        handle.write("\n")
    return span_path


def run_diagnostics(args: argparse.Namespace) -> int:
    repo = _repo_path(args.repo)
    if args.max_projects < 0:
        raise ValueError("--max-projects must be >= 0")
    started = time.monotonic()
    run_id = args.run_id or _run_id()
    changed_files = _git_changed_files(repo, args.base) if args.changed_only else []
    changed = set(changed_files)
    adapter_results = [
        _run_adapter(
            name,
            repo,
            args.timeout,
            explicit=args.adapter != "auto",
            max_projects=args.max_projects,
        )
        for name in _selected_adapters(args.adapter)
    ]
    diagnostics = [
        item
        for adapter in adapter_results
        for item in adapter.get("diagnostics", [])
        if isinstance(item, dict)
    ]
    if args.changed_only:
        diagnostics = [item for item in diagnostics if _changed_filter(item, changed)]
    summary = _summarize(diagnostics, adapter_results)
    status = _overall_status(summary, adapter_results)
    payload = {
        "schema": RESULT_SCHEMA,
        "run_id": run_id,
        "ts": _iso_utc(),
        "repo": repo,
        "adapter": args.adapter,
        "status": status,
        "changed_only": bool(args.changed_only),
        "base": args.base if args.changed_only else "",
        "changed_files": changed_files,
        "duration_ms": int((time.monotonic() - started) * 1000),
        "summary": summary,
        "adapters": [
            {key: value for key, value in adapter.items() if key != "diagnostics"}
            for adapter in adapter_results
        ],
        "diagnostics": diagnostics,
    }
    if args.output:
        output_path = os.path.abspath(os.path.expanduser(args.output))
        os.makedirs(os.path.dirname(output_path), exist_ok=True)
        with open(output_path, "w", encoding="utf-8") as handle:
            json.dump(payload, handle, indent=2, sort_keys=True)
            handle.write("\n")
        payload["output_path"] = output_path
    if args.emit_span:
        _default_spans = (os.path.join(legion_state.default_log_root(), "spans")
                          if legion_state else "~/.claude/logs/legion/spans")
        telemetry_dir = args.telemetry_dir or os.environ.get("LEGION_TELEMETRY_DIR") or _default_spans
        payload["span_path"] = _emit_span(payload, telemetry_dir)

    if args.json:
        print(json.dumps(payload, sort_keys=True))
    else:
        print(
            "legion-code-intel diagnostics: "
            f"{payload['status']} "
            f"{summary['errors']} errors, {summary['warnings']} warnings, "
            f"{summary['adapters_run']} adapter(s) run"
        )
        for item in diagnostics[:20]:
            location = item.get("file") or "<workspace>"
            if item.get("line"):
                location = f"{location}:{item.get('line')}:{item.get('column') or 1}"
            print(f"{location}: {item.get('severity')} {item.get('code')}: {item.get('message')}")
        if len(diagnostics) > 20:
            print(f"... {len(diagnostics) - 20} more diagnostic(s)")
    return _exit_code(status)


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        prog="legion-code-intel",
        description="Optional repo-native code-intelligence diagnostics for Legion.",
    )
    sub = parser.add_subparsers(dest="command", required=True)
    diag = sub.add_parser("diagnostics", help="run diagnostic adapters and emit a Legion artifact")
    diag.add_argument("--repo", default=".", help="repository root to inspect")
    diag.add_argument(
        "--adapter",
        default="auto",
        choices=("auto", "typescript", "pyright"),
        help="diagnostic adapter to run",
    )
    diag.add_argument("--changed-only", action="store_true", help="report diagnostics only in changed files")
    diag.add_argument("--base", default="HEAD", help="git base for --changed-only")
    diag.add_argument("--timeout", type=int, default=DEFAULT_TIMEOUT_SECONDS, help="adapter timeout in seconds")
    diag.add_argument(
        "--max-projects",
        type=int,
        default=DEFAULT_MAX_PROJECTS,
        help=(
            "maximum configured projects per adapter "
            f"(default: {DEFAULT_MAX_PROJECTS}; 0 = unlimited)"
        ),
    )
    diag.add_argument("--run-id", default="", help="stable run id for telemetry correlation")
    diag.add_argument("--output", default="", help="write the JSON artifact to this path")
    diag.add_argument("--emit-span", action="store_true", help="append a legion.span.v1 telemetry span")
    diag.add_argument("--telemetry-dir", default="", help="override LEGION_TELEMETRY_DIR for --emit-span")
    diag.add_argument("--json", action="store_true", help="print machine-readable JSON")
    diag.set_defaults(func=run_diagnostics)
    return parser


def main(argv: list[str] | None = None) -> int:
    parser = build_parser()
    args = parser.parse_args(argv)
    try:
        return int(args.func(args))
    except ValueError as exc:
        print(f"legion-code-intel: {exc}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
