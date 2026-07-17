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

sys.path.insert(0, os.path.join(
    os.path.dirname(os.path.abspath(__file__)), "..", "..", "legion-observability", "scripts"))
try:
    import legion_state  # noqa: E402
except ModuleNotFoundError:  # code-intel can ship without the observability plugin
    legion_state = None


RESULT_SCHEMA = "legion.code-intel.v1"
SPAN_SCHEMA = "legion.span.v1"
DEFAULT_TIMEOUT_SECONDS = 120
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
    timeout: int,
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


def _detect_typescript(repo: str) -> bool:
    if _has_file(repo, "tsconfig.json"):
        return True
    package_json = _load_json(os.path.join(repo, "package.json"))
    deps = {}
    for key in ("dependencies", "devDependencies", "peerDependencies"):
        value = package_json.get(key)
        if isinstance(value, dict):
            deps.update(value)
    return "typescript" in deps or _has_any_file(repo, (".ts", ".tsx"), limit=1)


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


def _typescript_adapter(repo: str, timeout: int) -> dict[str, Any]:
    if not _detect_typescript(repo):
        return {"name": "typescript", "status": "skipped", "reason": "no TypeScript project markers"}
    tsc = _local_typescript_bin(repo)
    if not tsc:
        return {"name": "typescript", "status": "skipped", "reason": "tsc not found"}
    argv = [tsc, "--noEmit", "--pretty", "false"]
    result = _command_result(argv, repo=repo, timeout=timeout)
    combined = f"{result['stdout']}\n{result['stderr']}"
    diagnostics = _parse_tsc(repo, combined)
    status = "ok" if result["returncode"] == 0 else "failed"
    if result["timed_out"]:
        status = "error"
    elif result["returncode"] != 0 and not diagnostics:
        status = "error"
    return {
        "name": "typescript",
        "status": status,
        "cmd": argv,
        "returncode": result["returncode"],
        "duration_ms": result["duration_ms"],
        "diagnostics": diagnostics,
        "parse_error": "tsc exited nonzero without parseable diagnostics" if status == "error" and not diagnostics else "",
        "raw_stdout_tail": result["stdout"][-4000:],
        "raw_stderr_tail": result["stderr"][-4000:],
    }


def _local_pyright_bin(repo: str) -> str:
    return (
        os.environ.get("LEGION_PYRIGHT_BIN", "")
        or _first_existing([os.path.join(repo, "node_modules", ".bin", "pyright")])
        or _which("pyright")
    )


def _detect_python(repo: str) -> bool:
    return (
        _has_file(repo, "pyrightconfig.json")
        or _has_file(repo, "pyproject.toml")
        or _has_any_file(repo, (".py",), limit=1)
    )


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


def _pyright_adapter(repo: str, timeout: int) -> dict[str, Any]:
    if not _detect_python(repo):
        return {"name": "pyright", "status": "skipped", "reason": "no Python project markers"}
    pyright = _local_pyright_bin(repo)
    if not pyright:
        return {"name": "pyright", "status": "skipped", "reason": "pyright not found"}
    argv = [pyright, "--outputjson"]
    result = _command_result(argv, repo=repo, timeout=timeout)
    diagnostics: list[dict[str, Any]] = []
    parse_error = ""
    try:
        diagnostics = _parse_pyright(repo, result["stdout"])
    except ValueError as exc:
        parse_error = str(exc)
    status = "ok" if result["returncode"] == 0 else "failed"
    if result["timed_out"] or parse_error:
        status = "error"
    elif result["returncode"] != 0 and not diagnostics:
        status = "error"
        parse_error = "pyright exited nonzero without diagnostics"
    return {
        "name": "pyright",
        "status": status,
        "cmd": argv,
        "returncode": result["returncode"],
        "duration_ms": result["duration_ms"],
        "diagnostics": diagnostics,
        "parse_error": parse_error,
        "raw_stdout_tail": result["stdout"][-4000:],
        "raw_stderr_tail": result["stderr"][-4000:],
    }


def _selected_adapters(name: str) -> list[str]:
    if name == "auto":
        return ["typescript", "pyright"]
    return [name]


def _run_adapter(name: str, repo: str, timeout: int) -> dict[str, Any]:
    if name == "typescript":
        return _typescript_adapter(repo, timeout)
    if name == "pyright":
        return _pyright_adapter(repo, timeout)
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
    started = time.monotonic()
    run_id = args.run_id or _run_id()
    changed_files = _git_changed_files(repo, args.base) if args.changed_only else []
    changed = set(changed_files)
    adapter_results = [_run_adapter(name, repo, args.timeout) for name in _selected_adapters(args.adapter)]
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
