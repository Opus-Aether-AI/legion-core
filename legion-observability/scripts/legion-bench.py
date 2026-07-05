#!/usr/bin/env python3
"""legion-bench - deterministic benchmark workbench for Legion harness changes."""

from __future__ import annotations

import argparse
import hashlib
import importlib.util
import json
import math
import os
import shlex
import subprocess
import sys
import time
from datetime import datetime, timezone
from typing import Any


SUITE_SCHEMA = "legion.bench.suite.v1"
CORPUS_SCHEMA = "legion.bench.corpus.v1"
CASE_RESULT_SCHEMA = "legion.bench.case-result.v1"
RUN_SCHEMA = "legion.bench.run.v1"
SUMMARY_SCHEMA = "legion.bench.summary.v1"
LATEST_SCHEMA = "legion.bench.latest.v1"
COMPARE_SCHEMA = "legion.bench.compare.v1"
OUTCOME_SCHEMA = "legion.outcome.v1"
SPAN_SCHEMA = "legion.span.v1"
DEFAULT_LOG_ROOT = os.environ.get("LEGION_STATE_ROOT", "~/.claude/logs/legion")
DEFAULT_BENCH_ROOT = os.environ.get(
    "LEGION_BENCH_DIR", os.path.join(DEFAULT_LOG_ROOT, "bench")
)
POSITIVE_QUALITY_METRICS = [
    "score",
    "pass_rate",
    "required_pass_rate",
    "eval_hit_at_1",
    "eval_hit_at_k",
    "learning_pass_rate",
    "route_match_rate",
    "task_pass_rate",
    "validation_pass_rate",
]
NEGATIVE_QUALITY_METRICS = [
    "fail",
    "required_fail",
    "false_success",
    "eval_miss",
    "eval_collision",
]
RATE_METRICS = set(POSITIVE_QUALITY_METRICS)


def _here() -> str:
    return os.path.dirname(os.path.abspath(__file__))


def default_repo() -> str:
    return os.path.abspath(os.path.join(_here(), "..", ".."))


def _load_module(name: str, path: str):
    spec = importlib.util.spec_from_file_location(name, path)
    if spec is None or spec.loader is None:
        raise RuntimeError(f"could not import {path}")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def _eval_module():
    return _load_module("legion_eval_for_bench", os.path.join(_here(), "legion-eval.py"))


def _route_module(repo: str):
    return _load_module(
        "legion_route_for_bench",
        os.path.join(repo, "legion-router", "scripts", "legion-route.py"),
    )


def _iso_utc() -> str:
    return datetime.now(timezone.utc).isoformat().replace("+00:00", "Z")


def _date_utc() -> str:
    return datetime.now(timezone.utc).strftime("%Y-%m-%d")


def _stable_id(parts: list[Any], length: int = 16) -> str:
    raw = json.dumps(parts, sort_keys=True, ensure_ascii=True, default=str)
    return hashlib.sha256(raw.encode("utf-8")).hexdigest()[:length]


def _text(value: Any) -> str:
    return value.strip() if isinstance(value, str) else ""


def _dict(value: Any) -> dict[str, Any]:
    return value if isinstance(value, dict) else {}


def _list(value: Any) -> list[Any]:
    return value if isinstance(value, list) else []


def _num(value: Any) -> float:
    if isinstance(value, bool):
        return 0.0
    if isinstance(value, (int, float)) and value == value:
        return float(value)
    return 0.0


def _relative_delta_pct(baseline: float, candidate: float) -> float | None:
    if baseline <= 0:
        return None
    return round(((candidate - baseline) / baseline) * 100, 3)


def _short(text: str, limit: int = 500) -> str:
    collapsed = " ".join(_text(text).split())
    if len(collapsed) <= limit:
        return collapsed
    return collapsed[: limit - 3].rstrip() + "..."


def _write_json(path: str, payload: Any) -> None:
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w", encoding="utf-8") as handle:
        json.dump(payload, handle, indent=2, sort_keys=True)
        handle.write("\n")


def _append_jsonl(path: str, payload: dict[str, Any]) -> None:
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "a", encoding="utf-8") as handle:
        handle.write(json.dumps(payload, sort_keys=True, ensure_ascii=False))
        handle.write("\n")


def _json_file(path: str) -> dict[str, Any]:
    try:
        with open(path, encoding="utf-8") as handle:
            data = json.load(handle)
    except (OSError, ValueError, TypeError) as exc:
        raise ValueError(f"could not read JSON file {path}: {exc}") from exc
    if not isinstance(data, dict):
        raise ValueError(f"expected JSON object in {path}")
    return data


def _read_text(path: str) -> str:
    try:
        with open(path, encoding="utf-8") as handle:
            return handle.read()
    except OSError:
        return ""


def _json_path(payload: Any, path: str) -> Any:
    current = payload
    for part in path.split("."):
        if isinstance(current, list):
            try:
                current = current[int(part)]
            except (ValueError, IndexError):
                return None
        elif isinstance(current, dict):
            current = current.get(part)
        else:
            return None
    return current


def _contains_expected(payload: Any, expected: Any) -> bool:
    if isinstance(expected, dict):
        if not isinstance(payload, dict):
            return False
        return all(key in payload and _contains_expected(payload[key], value) for key, value in expected.items())
    if isinstance(expected, list):
        if not isinstance(payload, list) or len(payload) < len(expected):
            return False
        return all(_contains_expected(item, expected[index]) for index, item in enumerate(payload[: len(expected)]))
    return payload == expected


def _render(value: Any, context: dict[str, str]) -> Any:
    if isinstance(value, str):
        out = value
        for key, replacement in context.items():
            out = out.replace("{" + key + "}", replacement)
        return out
    if isinstance(value, list):
        return [_render(item, context) for item in value]
    if isinstance(value, dict):
        return {key: _render(item, context) for key, item in value.items()}
    return value


def _safe_child(root: str, rel: str) -> str:
    if os.path.isabs(rel):
        raise ValueError(f"absolute fixture paths are not allowed: {rel}")
    path = os.path.abspath(os.path.join(root, rel))
    if os.path.commonpath([os.path.abspath(root), path]) != os.path.abspath(root):
        raise ValueError(f"fixture path escapes workspace: {rel}")
    return path


def _write_fixture_files(workspace: str, files: dict[str, Any], context: dict[str, str]) -> None:
    for rel, raw_content in sorted(files.items()):
        path = _safe_child(workspace, rel)
        os.makedirs(os.path.dirname(path), exist_ok=True)
        content = _render(raw_content, context)
        if isinstance(content, (dict, list)):
            text = json.dumps(content, indent=2, sort_keys=True) + "\n"
        else:
            text = str(content)
        with open(path, "w", encoding="utf-8") as handle:
            handle.write(text)


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


def resolve_suite_path(repo: str, suite: str) -> str:
    expanded = os.path.abspath(os.path.expanduser(suite))
    if os.path.exists(expanded):
        return expanded
    if os.path.sep in suite or suite.endswith(".json"):
        candidate = os.path.abspath(os.path.join(os.getcwd(), suite))
        if os.path.exists(candidate):
            return candidate
    name = suite[:-5] if suite.endswith(".json") else suite
    candidate = os.path.join(repo, "legion-observability", "bench", f"{name}.json")
    if os.path.exists(candidate):
        return os.path.abspath(candidate)
    raise FileNotFoundError(f"benchmark suite not found: {suite}")


def resolve_suite_include_path(repo: str, include: str, parent_path: str) -> str:
    if parent_path:
        parent_dir = os.path.dirname(os.path.abspath(parent_path))
        name = include[:-5] if include.endswith(".json") else include
        for candidate in (
            os.path.abspath(os.path.join(parent_dir, include)),
            os.path.abspath(os.path.join(parent_dir, f"{name}.json")),
        ):
            if os.path.exists(candidate):
                return candidate
    return resolve_suite_path(repo, include)


def resolve_corpus_path(repo: str, corpus: str) -> str:
    expanded = os.path.abspath(os.path.expanduser(corpus))
    if os.path.exists(expanded):
        return expanded
    if os.path.sep in corpus or corpus.endswith(".json"):
        candidate = os.path.abspath(os.path.join(os.getcwd(), corpus))
        if os.path.exists(candidate):
            return candidate
    name = corpus[:-5] if corpus.endswith(".json") else corpus
    for rel in (
        os.path.join("legion-observability", "bench", "corpora", f"{name}.json"),
        os.path.join("legion-observability", "bench", f"{name}.json"),
    ):
        candidate = os.path.join(repo, rel)
        if os.path.exists(candidate):
            return os.path.abspath(candidate)
    raise FileNotFoundError(f"benchmark corpus not found: {corpus}")


def load_suite(repo: str, suite: str, seen: set[str] | None = None) -> dict[str, Any]:
    path = resolve_suite_path(repo, suite)
    seen = seen or set()
    if path in seen:
        raise ValueError(f"benchmark suite include cycle: {path}")
    next_seen = set(seen)
    next_seen.add(path)
    payload = _json_file(path)
    if payload.get("schema") != SUITE_SCHEMA:
        raise ValueError(f"{path} is not a {SUITE_SCHEMA} suite")
    cases: list[Any] = []
    for include in _list(payload.get("extends")):
        include_name = _text(include)
        if not include_name:
            continue
        include_path = resolve_suite_include_path(repo, include_name, path)
        cases.extend(_list(load_suite(repo, include_path, next_seen).get("cases")))
    cases.extend(_list(payload.get("cases")))
    if not isinstance(cases, list) or not cases:
        raise ValueError(f"{path} has no benchmark cases")
    payload["cases"] = cases
    payload["_path"] = path
    return payload


def load_corpus(repo: str, corpus: str) -> dict[str, Any]:
    path = resolve_corpus_path(repo, corpus)
    payload = _json_file(path)
    if payload.get("schema") != CORPUS_SCHEMA:
        raise ValueError(f"{path} is not a {CORPUS_SCHEMA} corpus")
    modes = _list(payload.get("modes"))
    cases = _list(payload.get("cases"))
    if not modes:
        raise ValueError(f"{path} has no benchmark modes")
    if not cases:
        raise ValueError(f"{path} has no benchmark cases")
    seen_modes: set[str] = set()
    for mode in modes:
        mode_id = _text(_dict(mode).get("id"))
        if not mode_id:
            raise ValueError(f"{path} has a mode without id")
        if mode_id in seen_modes:
            raise ValueError(f"{path} has duplicate mode id: {mode_id}")
        seen_modes.add(mode_id)
    seen_cases: set[str] = set()
    for case in cases:
        case_id = _text(_dict(case).get("id"))
        if not case_id:
            raise ValueError(f"{path} has a case without id")
        if case_id in seen_cases:
            raise ValueError(f"{path} has duplicate case id: {case_id}")
        seen_cases.add(case_id)
    payload["_path"] = path
    return payload


def _case_target(case: dict[str, Any]) -> tuple[str, str]:
    target_type = _text(case.get("target_type"))
    target_name = _text(case.get("target_name"))
    if target_type and target_name:
        return target_type, target_name
    case_type = _text(case.get("type"))
    if case_type == "eval":
        return _text(case.get("expect_type")) or "plugin", _text(case.get("expect"))
    if case_type == "route":
        return "plugin", "legion-router"
    return "plugin", "legion-observability"


def _eval_scope(eval_module: Any, eval_case: dict[str, Any], requested: str) -> str:
    if hasattr(eval_module, "_scope_for_cases"):
        return eval_module._scope_for_cases([eval_case], requested)
    if requested != "auto":
        return requested
    return "entity" if eval_case.get("expect_type") not in (None, "plugin") else "plugin"


def run_eval_case(case: dict[str, Any], repo: str) -> dict[str, Any]:
    le = _eval_module()
    eval_case = {
        "prompt": case["prompt"],
        "expect": case.get("expect"),
        "expect_type": case.get("expect_type") or "plugin",
    }
    for key in ("expect_not", "expect_not_type", "why"):
        if case.get(key):
            eval_case[key] = case[key]
    top_k = int(case.get("top_k") or 3)
    gap = float(case.get("gap") or 0.5)
    scope = _eval_scope(le, eval_case, _text(case.get("scope")) or "auto")
    targets = le.load_targets(repo, scope)
    details = le.evaluate_case(eval_case, targets, top_k, gap)
    ok = details.get("status") == "pass"
    reason = "expected target won" if ok else (
        f"expect={details.get('expect')} got={details.get('got')} "
        f"status={details.get('status')}"
    )
    return {
        "ok": ok,
        "reason": reason,
        "false_success": bool(details.get("false_trigger")),
        "metrics": {
            "eval_in_top1": 1 if details.get("in_top1") else 0,
            "eval_in_topk": 1 if details.get("in_topk") else 0,
            "eval_miss": 1 if details.get("status") == "miss" else 0,
            "eval_collision": 1 if details.get("status") == "collision" else 0,
        },
        "details": details,
    }


def _route_file(repo: str, case: dict[str, Any]) -> str:
    if case.get("file"):
        return os.path.abspath(os.path.expanduser(str(case["file"])))
    return os.path.join(repo, "legion-router", "config", "routing.toml")


def run_route_case(case: dict[str, Any], repo: str) -> dict[str, Any]:
    module = _route_module(repo)
    route_file = _route_file(repo, case)
    table = module.load_table(route_file)
    archetype = _text(case.get("archetype"))
    if not archetype:
        raise ValueError("route case requires archetype")
    resolved = module.resolve(table, archetype)
    expected = _dict(case.get("expect"))
    mismatches: dict[str, dict[str, Any]] = {}
    for key, value in expected.items():
        if resolved.get(key) != value:
            mismatches[key] = {"expect": value, "got": resolved.get(key)}
    ok = bool(resolved.get("resolved")) and not mismatches
    return {
        "ok": ok,
        "reason": "route matched expected policy" if ok else f"route mismatch: {mismatches}",
        "false_success": False,
        "metrics": {"route_match": 1 if ok else 0},
        "details": {
            "archetype": archetype,
            "expect": expected,
            "resolved": resolved,
            "mismatches": mismatches,
            "file": route_file,
        },
    }


def run_doctor_case(case: dict[str, Any], repo: str) -> dict[str, Any]:
    doctor = os.path.join(repo, "legion-observability", "bin", "legion-doctor")
    argv = [doctor, "--repo", repo]
    if case.get("only"):
        argv.extend(["--only", str(case["only"])])
    timeout = int(case.get("timeout") or 90)
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
        duration_ms = int((time.monotonic() - start) * 1000)
        ok = proc.returncode == 0
        return {
            "ok": ok,
            "reason": "doctor check passed" if ok else f"doctor exited {proc.returncode}",
            "false_success": False,
            "metrics": {"validation_pass": 1 if ok else 0},
            "details": {
                "cmd": argv,
                "returncode": proc.returncode,
                "duration_ms": duration_ms,
                "stdout": proc.stdout[-4000:],
                "stderr": proc.stderr[-4000:],
            },
        }
    except subprocess.TimeoutExpired as exc:
        return {
            "ok": False,
            "reason": f"doctor timed out after {timeout}s",
            "false_success": False,
            "metrics": {"validation_pass": 0},
            "details": {"cmd": argv, "error": str(exc), "timeout": timeout},
        }


def _validator_result(kind: str, ok: bool, detail: str = "") -> dict[str, Any]:
    return {"type": kind, "ok": ok, "detail": detail}


def _validate_jsonl_contains(path: str, expected: dict[str, Any]) -> bool:
    try:
        with open(path, encoding="utf-8") as handle:
            for line in handle:
                try:
                    payload = json.loads(line)
                except ValueError:
                    continue
                if _contains_expected(payload, expected):
                    return True
    except OSError:
        return False
    return False


def run_task_validators(
    validators: list[Any],
    *,
    context: dict[str, str],
    stdout: str,
    stderr: str,
    env: dict[str, str] | None = None,
) -> list[dict[str, Any]]:
    results: list[dict[str, Any]] = []
    for raw_validator in validators:
        validator = _dict(raw_validator)
        kind = _text(validator.get("type"))
        if kind == "stdout_contains":
            needle = _text(_render(validator.get("text"), context))
            results.append(_validator_result(kind, needle in stdout, needle))
        elif kind == "stderr_contains":
            needle = _text(_render(validator.get("text"), context))
            results.append(_validator_result(kind, needle in stderr, needle))
        elif kind == "file_exists":
            path = _text(_render(validator.get("path"), context))
            results.append(_validator_result(kind, os.path.exists(path), path))
        elif kind == "file_contains":
            path = _text(_render(validator.get("path"), context))
            needle = _text(_render(validator.get("text"), context))
            results.append(_validator_result(kind, needle in _read_text(path), f"{path}: {needle}"))
        elif kind == "json_file_field_equals":
            path = _text(_render(validator.get("path"), context))
            field = _text(validator.get("field"))
            try:
                got = _json_path(_json_file(path), field)
            except ValueError:
                got = None
            expected = _render(validator.get("equals"), context)
            results.append(_validator_result(kind, got == expected, f"{path}:{field}"))
        elif kind == "stdout_json_field_equals":
            field = _text(validator.get("field"))
            try:
                got = _json_path(json.loads(stdout), field)
            except ValueError:
                got = None
            expected = _render(validator.get("equals"), context)
            results.append(_validator_result(kind, got == expected, field))
        elif kind == "jsonl_contains":
            path = _text(_render(validator.get("path"), context))
            expected = _dict(_render(validator.get("match"), context))
            results.append(_validator_result(kind, _validate_jsonl_contains(path, expected), path))
        elif kind == "command":
            command = validator.get("command")
            cwd = _text(_render(validator.get("cwd") or "{workspace}", context))
            timeout = int(validator.get("timeout") or 120)
            expected_exit = int(validator.get("expect_exit") or 0)
            result = _run_process_command(
                command,
                context=context,
                cwd=cwd,
                env=env or os.environ.copy(),
                timeout=timeout,
            )
            ok = result.get("returncode") == expected_exit
            detail = (
                f"exit={result.get('returncode')} expected={expected_exit}; "
                f"stdout={_short(_text(result.get('stdout')), 500)}; "
                f"stderr={_short(_text(result.get('stderr')), 500)}"
            )
            results.append(_validator_result(kind, ok, detail))
        else:
            results.append(_validator_result(kind or "unknown", False, "unknown validator"))
    return results


def _command_argv(command: Any, context: dict[str, str]) -> list[str]:
    rendered = _render(command, context)
    if isinstance(rendered, str):
        return shlex.split(rendered)
    if isinstance(rendered, list) and all(isinstance(item, str) for item in rendered):
        return rendered
    raise ValueError("command must be a string or string list")


def _run_process_command(
    command: Any,
    *,
    context: dict[str, str],
    cwd: str,
    env: dict[str, str],
    timeout: int,
) -> dict[str, Any]:
    argv = _command_argv(command, context)
    start = time.monotonic()
    try:
        proc = subprocess.run(
            argv,
            cwd=cwd,
            env=env,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            timeout=timeout,
        )
        return {
            "cmd": argv,
            "cwd": cwd,
            "returncode": proc.returncode,
            "duration_ms": int((time.monotonic() - start) * 1000),
            "stdout": proc.stdout,
            "stderr": proc.stderr,
        }
    except subprocess.TimeoutExpired as exc:
        return {
            "cmd": argv,
            "cwd": cwd,
            "returncode": None,
            "duration_ms": int((time.monotonic() - start) * 1000),
            "stdout": exc.stdout or "",
            "stderr": exc.stderr or "",
            "timed_out": True,
            "error": str(exc),
        }
    except OSError as exc:
        return {
            "cmd": argv,
            "cwd": cwd,
            "returncode": None,
            "duration_ms": int((time.monotonic() - start) * 1000),
            "stdout": "",
            "stderr": "",
            "error": str(exc),
        }


_PROVIDER_BLOCK_PATTERNS: tuple[tuple[str, tuple[str, ...]], ...] = (
    ("provider_usage_limit", ("usage limit", "hit your usage limit", "try again at")),
    ("provider_session_limit", ("session limit", "hit your session limit")),
    ("provider_quota", ("quota", "insufficient_quota", "credits")),
    ("provider_rate_limit", ("rate limit", "rate-limit", "rate_limit", "too many requests")),
)


def _provider_block_reason(result: dict[str, Any]) -> str:
    haystack = " ".join(
        _text(result.get(key))
        for key in ("stdout", "stderr", "error")
        if result.get(key) is not None
    ).lower()
    if not haystack:
        return ""
    for reason, needles in _PROVIDER_BLOCK_PATTERNS:
        if any(needle in haystack for needle in needles):
            return reason
    return ""


def _span_token_total(tokens: Any) -> int:
    if isinstance(tokens, bool):
        return 0
    if isinstance(tokens, (int, float)):
        return max(0, int(tokens))
    if not isinstance(tokens, dict):
        return 0
    for key in ("total_tokens", "tokens", "total"):
        value = tokens.get(key)
        if isinstance(value, (int, float)) and not isinstance(value, bool):
            return max(0, int(value))
    total = 0
    for key in ("input_tokens", "output_tokens", "cache_read_input_tokens", "cache_creation_input_tokens"):
        value = tokens.get(key)
        if isinstance(value, (int, float)) and not isinstance(value, bool):
            total += max(0, int(value))
    return total


def _span_totals(logs: str) -> dict[str, Any]:
    spans_dir = os.path.join(logs, "spans")
    totals: dict[str, Any] = {
        "span_count": 0,
        "cost_usd": 0.0,
        "span_duration_ms": 0,
        "tokens": 0,
        "models": {},
    }
    if not os.path.isdir(spans_dir):
        return totals
    for name in sorted(os.listdir(spans_dir)):
        if not name.endswith(".jsonl"):
            continue
        path = os.path.join(spans_dir, name)
        try:
            with open(path, encoding="utf-8") as handle:
                for line in handle:
                    try:
                        span = json.loads(line)
                    except ValueError:
                        continue
                    if not isinstance(span, dict):
                        continue
                    span_cost = _num(span.get("cost_usd"))
                    span_duration = int(_num(span.get("duration_ms")))
                    span_tokens = _span_token_total(span.get("tokens"))
                    model = _text(span.get("model")) or "unknown"
                    totals["span_count"] += 1
                    totals["cost_usd"] = round(float(totals["cost_usd"]) + span_cost, 6)
                    totals["span_duration_ms"] += span_duration
                    totals["tokens"] += span_tokens
                    model_totals = totals["models"].setdefault(
                        model,
                        {"span_count": 0, "cost_usd": 0.0, "span_duration_ms": 0, "tokens": 0},
                    )
                    model_totals["span_count"] += 1
                    model_totals["cost_usd"] = round(float(model_totals["cost_usd"]) + span_cost, 6)
                    model_totals["span_duration_ms"] += span_duration
                    model_totals["tokens"] += span_tokens
        except OSError:
            continue
    totals["models"] = dict(sorted(totals["models"].items()))
    return totals


def run_task_case(case: dict[str, Any], repo: str, run_dir: str) -> dict[str, Any]:
    case_id = _text(case.get("id")) or _stable_id([case])
    safe_case_id = "".join(ch if ch.isalnum() or ch in "._-" else "-" for ch in case_id)
    workspace = os.path.join(run_dir, "workspaces", safe_case_id)
    home = os.path.join(workspace, "home")
    logs = os.path.join(workspace, "logs")
    os.makedirs(home, exist_ok=True)
    os.makedirs(logs, exist_ok=True)
    context = {
        "repo": os.path.abspath(repo),
        "workspace": workspace,
        "home": home,
        "logs": logs,
        "case_id": case_id,
        "run_dir": run_dir,
    }
    _write_fixture_files(workspace, _dict(case.get("files")), context)

    argv = _command_argv(case.get("command"), context)

    env = os.environ.copy()
    env.update({
        "HOME": home,
        "LEGION_TELEMETRY_DIR": os.path.join(logs, "spans"),
        "PYTHONUNBUFFERED": "1",
    })
    env.update({key: str(value) for key, value in _dict(_render(case.get("env"), context)).items()})
    cwd = _text(_render(case.get("cwd") or "{workspace}", context))
    timeout = int(case.get("timeout") or 120)
    expected_exit = int(case.get("expect_exit") or 0)
    start = time.monotonic()
    try:
        proc = subprocess.run(
            argv,
            cwd=cwd,
            env=env,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            timeout=timeout,
        )
        duration_ms = int((time.monotonic() - start) * 1000)
        validator_results = run_task_validators(
            _list(case.get("validators")),
            context=context,
            stdout=proc.stdout,
            stderr=proc.stderr,
            env=env,
        )
        exit_ok = proc.returncode == expected_exit
        validators_ok = all(result.get("ok") for result in validator_results)
        ok = exit_ok and validators_ok
        return {
            "ok": ok,
            "reason": "task command and validators passed" if ok else (
                f"exit={proc.returncode} expected={expected_exit}; "
                f"validators={sum(1 for item in validator_results if item.get('ok'))}/{len(validator_results)}"
            ),
            "false_success": False,
            "metrics": {
                "task_pass": 1 if ok else 0,
                "validation_pass": 1 if ok else 0,
            },
            "details": {
                "cmd": argv,
                "cwd": cwd,
                "workspace": workspace,
                "logs": logs,
                "returncode": proc.returncode,
                "expected_exit": expected_exit,
                "duration_ms": duration_ms,
                "validators": validator_results,
                "stdout": proc.stdout[-4000:],
                "stderr": proc.stderr[-4000:],
            },
        }
    except subprocess.TimeoutExpired as exc:
        return {
            "ok": False,
            "reason": f"task timed out after {timeout}s",
            "false_success": False,
            "metrics": {"task_pass": 0, "validation_pass": 0},
            "details": {"cmd": argv, "cwd": cwd, "workspace": workspace, "error": str(exc)},
        }


def run_case(case: dict[str, Any], repo: str, run_dir: str) -> dict[str, Any]:
    started_at = _iso_utc()
    start = time.monotonic()
    case_id = _text(case.get("id"))
    case_type = _text(case.get("type"))
    required = bool(case.get("required", True))
    target_type, target_name = _case_target(case)
    try:
        if case_type == "eval":
            payload = run_eval_case(case, repo)
        elif case_type == "route":
            payload = run_route_case(case, repo)
        elif case_type == "doctor":
            payload = run_doctor_case(case, repo)
        elif case_type == "task":
            payload = run_task_case(case, repo, run_dir)
        else:
            raise ValueError(f"unknown benchmark case type: {case_type}")
    except Exception as exc:
        payload = {
            "ok": False,
            "reason": str(exc),
            "false_success": False,
            "metrics": {},
            "details": {"error": str(exc), "error_type": type(exc).__name__},
        }
    duration_ms = int((time.monotonic() - start) * 1000)
    ok = bool(payload.get("ok"))
    return {
        "schema": CASE_RESULT_SCHEMA,
        "id": case_id,
        "type": case_type,
        "required": required,
        "status": "pass" if ok else "fail",
        "ok": ok,
        "started_at": started_at,
        "duration_ms": duration_ms,
        "target_type": target_type,
        "target_name": target_name,
        "summary": _text(case.get("summary")) or _text(case.get("why")),
        "dimension": _text(case.get("dimension")) or case_type or "uncategorized",
        "reason": _short(_text(payload.get("reason")), 500),
        "false_success": bool(payload.get("false_success")),
        "metrics": _dict(payload.get("metrics")),
        "details": _dict(payload.get("details")),
    }


def _rate(numer: int, denom: int) -> float:
    return round(numer / denom, 6) if denom else 0.0


def summarize_dimensions(results: list[dict[str, Any]]) -> dict[str, dict[str, Any]]:
    out: dict[str, dict[str, Any]] = {}
    for result in results:
        dimension = _text(result.get("dimension")) or _text(result.get("type")) or "uncategorized"
        entry = out.setdefault(
            dimension,
            {
                "cases": 0,
                "pass": 0,
                "fail": 0,
                "required_cases": 0,
                "required_pass": 0,
                "required_fail": 0,
            },
        )
        entry["cases"] += 1
        if result.get("status") == "pass":
            entry["pass"] += 1
        else:
            entry["fail"] += 1
        if result.get("required"):
            entry["required_cases"] += 1
            if result.get("status") == "pass":
                entry["required_pass"] += 1
            else:
                entry["required_fail"] += 1
    for entry in out.values():
        entry["pass_rate"] = _rate(int(entry["pass"]), int(entry["cases"]))
        entry["required_pass_rate"] = _rate(int(entry["required_pass"]), int(entry["required_cases"]))
    return dict(sorted(out.items()))


def summarize_run(
    suite: dict[str, Any],
    results: list[dict[str, Any]],
    *,
    run_id: str,
    repo: str,
    duration_ms: int,
) -> dict[str, Any]:
    cases = len(results)
    passed = sum(1 for result in results if result.get("status") == "pass")
    required = [result for result in results if result.get("required")]
    required_pass = sum(1 for result in required if result.get("status") == "pass")
    eval_results = [result for result in results if result.get("type") == "eval"]
    learning_results = [result for result in results if result.get("type") == "learning"]
    route_results = [result for result in results if result.get("type") == "route"]
    doctor_results = [result for result in results if result.get("type") == "doctor"]
    task_results = [result for result in results if result.get("type") == "task"]
    eval_cases = len(eval_results)
    learning_cases = len(learning_results)
    route_cases = len(route_results)
    doctor_cases = len(doctor_results)
    task_cases = len(task_results)
    eval_top1 = sum(int(_dict(result.get("metrics")).get("eval_in_top1") or 0) for result in eval_results)
    eval_topk = sum(int(_dict(result.get("metrics")).get("eval_in_topk") or 0) for result in eval_results)
    eval_miss = sum(int(_dict(result.get("metrics")).get("eval_miss") or 0) for result in eval_results)
    eval_collision = sum(
        int(_dict(result.get("metrics")).get("eval_collision") or 0) for result in eval_results
    )
    learning_pass = sum(1 for result in learning_results if result.get("status") == "pass")
    route_match = sum(1 for result in route_results if result.get("status") == "pass")
    validation_pass = sum(1 for result in doctor_results if result.get("status") == "pass")
    task_pass = sum(1 for result in task_results if result.get("status") == "pass")
    false_success = sum(1 for result in results if result.get("false_success"))
    metrics = {
        "cases": cases,
        "pass": passed,
        "fail": cases - passed,
        "required_cases": len(required),
        "required_pass": required_pass,
        "required_fail": len(required) - required_pass,
        "pass_rate": _rate(passed, cases),
        "required_pass_rate": _rate(required_pass, len(required)),
        "score": _rate(required_pass, len(required)),
        "eval_cases": eval_cases,
        "eval_pass": sum(1 for result in eval_results if result.get("status") == "pass"),
        "eval_miss": eval_miss,
        "eval_collision": eval_collision,
        "eval_hit_at_1": _rate(eval_top1, eval_cases),
        "eval_hit_at_k": _rate(eval_topk, eval_cases),
        "learning_cases": learning_cases,
        "learning_pass": learning_pass,
        "learning_pass_rate": _rate(learning_pass, learning_cases),
        "route_cases": route_cases,
        "route_match": route_match,
        "route_match_rate": _rate(route_match, route_cases),
        "task_cases": task_cases,
        "task_pass": task_pass,
        "task_pass_rate": _rate(task_pass, task_cases),
        "validation_cases": doctor_cases,
        "validation_pass": validation_pass,
        "validation_pass_rate": _rate(validation_pass, doctor_cases),
        "false_success": false_success,
        "cost_usd": 0.0,
        "duration_ms": duration_ms,
        "tokens": 0,
    }
    return {
        "schema": SUMMARY_SCHEMA,
        "run_id": run_id,
        "suite": suite.get("suite"),
        "generated_at": _iso_utc(),
        "repo": os.path.abspath(repo),
        "commit": _git_commit(repo),
        "ok": metrics["required_fail"] == 0,
        "gate": _dict(suite.get("gate")),
        "metrics": metrics,
        "dimensions": summarize_dimensions(results),
    }


def _run_id(suite_name: str) -> str:
    stamp = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ")
    return f"{stamp}-{suite_name}-{_stable_id([stamp, suite_name, os.getpid(), time.time_ns()], 8)}"


def write_run_artifacts(
    bench_dir: str,
    run_id: str,
    suite: dict[str, Any],
    results: list[dict[str, Any]],
    summary: dict[str, Any],
) -> dict[str, str]:
    root = os.path.abspath(os.path.expanduser(bench_dir))
    run_dir = os.path.join(root, "runs", run_id)
    os.makedirs(run_dir, exist_ok=True)
    cases_path = os.path.join(run_dir, "cases.jsonl")
    summary_path = os.path.join(run_dir, "summary.json")
    run_path = os.path.join(run_dir, "run.json")
    latest_path = os.path.join(root, "latest.json")
    with open(cases_path, "w", encoding="utf-8") as handle:
        for result in results:
            handle.write(json.dumps(result, sort_keys=True, ensure_ascii=False))
            handle.write("\n")
    _write_json(summary_path, summary)
    run_payload = {
        "schema": RUN_SCHEMA,
        "run_id": run_id,
        "generated_at": summary.get("generated_at"),
        "suite": suite.get("suite"),
        "suite_path": suite.get("_path"),
        "repo": summary.get("repo"),
        "commit": summary.get("commit"),
        "summary": summary,
        "cases": results,
        "artifacts": {
            "run": run_path,
            "summary": summary_path,
            "cases": cases_path,
        },
    }
    _write_json(run_path, run_payload)
    _write_json(
        latest_path,
        {
            "schema": LATEST_SCHEMA,
            "run_id": run_id,
            "suite": suite.get("suite"),
            "run_path": run_path,
            "summary_path": summary_path,
            "cases_path": cases_path,
            "generated_at": summary.get("generated_at"),
        },
    )
    return {
        "run_dir": run_dir,
        "run_path": run_path,
        "summary_path": summary_path,
        "cases_path": cases_path,
        "latest_path": latest_path,
    }


def emit_bench_span(summary: dict[str, Any], artifacts: dict[str, str], telemetry_dir: str) -> str:
    telemetry_root = os.path.abspath(os.path.expanduser(telemetry_dir))
    os.makedirs(telemetry_root, exist_ok=True)
    path = os.path.join(telemetry_root, f"{_date_utc()}.jsonl")
    span = {
        "schema": SPAN_SCHEMA,
        "ts": _iso_utc(),
        "run_id": summary.get("run_id"),
        "trace_id": summary.get("run_id"),
        "parent_id": None,
        "executor": "legion-bench",
        "model": "offline",
        "task": f"legion-bench suite {summary.get('suite')}",
        "status": "ok" if summary.get("ok") else "failed",
        "target_type": "plugin",
        "target_name": "legion-observability",
        "duration_ms": _dict(summary.get("metrics")).get("duration_ms", 0),
        "cost_usd": 0,
        "tokens": {},
        "artifacts": {
            "bench_run": artifacts.get("run_path"),
            "bench_summary": artifacts.get("summary_path"),
            "bench_cases": artifacts.get("cases_path"),
        },
    }
    _append_jsonl(path, span)
    return path


def _outcomes_path(log_root: str) -> str:
    return os.path.join(os.path.expanduser(log_root), "self-learn", "outcomes.jsonl")


def _existing_outcome_ids(path: str) -> set[str]:
    out: set[str] = set()
    try:
        with open(path, encoding="utf-8") as handle:
            for line in handle:
                try:
                    payload = json.loads(line)
                except ValueError:
                    continue
                if isinstance(payload, dict) and payload.get("id"):
                    out.add(str(payload["id"]))
    except OSError:
        pass
    return out


def record_failed_outcomes(
    results: list[dict[str, Any]],
    *,
    log_root: str,
    run_path: str,
    run_id: str,
    suite_name: str,
) -> list[dict[str, Any]]:
    path = _outcomes_path(log_root)
    existing = _existing_outcome_ids(path)
    recorded: list[dict[str, Any]] = []
    for result in results:
        if result.get("status") == "pass" or not result.get("required"):
            continue
        target_type = _text(result.get("target_type")) or "plugin"
        target_name = _text(result.get("target_name")) or "legion-observability"
        case_id = _text(result.get("id"))
        summary = _short(
            f"Benchmark {suite_name}/{case_id} failed: {result.get('reason')}",
            500,
        )
        outcome_id = _stable_id(["legion-bench", target_type, target_name, suite_name, case_id, summary])
        if outcome_id in existing:
            continue
        outcome = {
            "schema": OUTCOME_SCHEMA,
            "id": outcome_id,
            "ts": _iso_utc(),
            "source": "legion-bench",
            "target_type": target_type,
            "target_name": target_name,
            "severity": "medium",
            "summary": summary,
            "evidence": _short(f"{run_path}#{case_id}: {result.get('reason')}", 1200),
            "run_id": run_id,
            "source_path": run_path,
            "metadata": {
                "suite": suite_name,
                "case_id": case_id,
                "case_type": result.get("type"),
                "status": result.get("status"),
                "details": result.get("details"),
            },
        }
        _append_jsonl(path, outcome)
        existing.add(outcome_id)
        recorded.append(outcome)
    return recorded


def record_failed_corpus_outcomes(
    results: list[dict[str, Any]],
    *,
    log_root: str,
    run_path: str,
    run_id: str,
    corpus_name: str,
) -> list[dict[str, Any]]:
    """Record failed required corpus case-runs as self-learning outcomes.

    A corpus failure is attributed to the harness MODE that produced it (e.g.
    legion-delegate / legion-cursor / direct-codex), so legion-self-learn can
    target the right entity. This closes the benchmarking.md learning-feedback
    loop for the live corpus path, mirroring record_failed_outcomes for suites.
    """
    path = _outcomes_path(log_root)
    existing = _existing_outcome_ids(path)
    recorded: list[dict[str, Any]] = []
    for result in results:
        if result.get("status") == "pass" or not result.get("required"):
            continue
        mode = _text(result.get("mode")) or "unknown-mode"
        case_id = _text(result.get("id"))
        dimension = _text(result.get("dimension")) or "corpus"
        is_harness_mode = mode.startswith(("legion-", "direct-", "cursor-"))
        target_type = "command" if is_harness_mode else "plugin"
        target_name = mode if is_harness_mode else "legion-observability"
        summary = _short(
            f"Corpus {corpus_name}: mode {mode} failed {case_id} ({dimension}): {result.get('reason')}",
            500,
        )
        outcome_id = _stable_id(
            ["legion-bench-corpus", target_type, target_name, corpus_name, mode, case_id, summary]
        )
        if outcome_id in existing:
            continue
        outcome = {
            "schema": OUTCOME_SCHEMA,
            "id": outcome_id,
            "ts": _iso_utc(),
            "source": "legion-bench",
            "target_type": target_type,
            "target_name": target_name,
            "severity": "medium",
            "summary": summary,
            "evidence": _short(f"{run_path}#{mode}/{case_id}: {result.get('reason')}", 1200),
            "run_id": run_id,
            "source_path": run_path,
            "metadata": {
                "corpus": corpus_name,
                "mode": mode,
                "case_id": case_id,
                "dimension": dimension,
                "attempt": result.get("attempt"),
                "status": result.get("status"),
            },
        }
        _append_jsonl(path, outcome)
        existing.add(outcome_id)
        recorded.append(outcome)
    return recorded


def load_run_or_summary(path: str) -> dict[str, Any]:
    payload = _json_file(os.path.abspath(os.path.expanduser(path)))
    schema = payload.get("schema")
    if schema == RUN_SCHEMA:
        summary = _dict(payload.get("summary"))
        if summary.get("schema") != SUMMARY_SCHEMA:
            raise ValueError(f"{path} has no valid summary")
        return summary
    if schema == SUMMARY_SCHEMA:
        return payload
    raise ValueError(f"{path} is not a {RUN_SCHEMA} or {SUMMARY_SCHEMA} artifact")


def _metric(summary: dict[str, Any], key: str) -> float:
    return _num(_dict(summary.get("metrics")).get(key))


def compare_summaries(baseline: dict[str, Any], candidate: dict[str, Any]) -> dict[str, Any]:
    keys = sorted(set(_dict(baseline.get("metrics"))) | set(_dict(candidate.get("metrics"))))
    metrics: dict[str, dict[str, Any]] = {}
    for key in keys:
        baseline_value = _metric(baseline, key)
        candidate_value = _metric(candidate, key)
        delta = round(candidate_value - baseline_value, 6)
        payload: dict[str, Any] = {
            "baseline": baseline_value,
            "candidate": candidate_value,
            "delta": delta,
        }
        if key in RATE_METRICS:
            payload["delta_pct_points"] = round(delta * 100, 3)
            payload["relative_improvement_pct"] = _relative_delta_pct(baseline_value, candidate_value)
        else:
            payload["relative_change_pct"] = _relative_delta_pct(baseline_value, candidate_value)
        metrics[key] = payload
    regressions: list[str] = []
    improvements: list[str] = []
    for key in POSITIVE_QUALITY_METRICS:
        delta = metrics.get(key, {}).get("delta", 0)
        if delta < -1e-9:
            regressions.append(key)
        elif delta > 1e-9:
            improvements.append(key)
    for key in NEGATIVE_QUALITY_METRICS:
        delta = metrics.get(key, {}).get("delta", 0)
        if delta > 1e-9:
            regressions.append(key)
        elif delta < -1e-9:
            improvements.append(key)
    status = "regressed" if regressions else ("improved" if improvements else "neutral")
    score = metrics.get("score", {"baseline": 0.0, "candidate": 0.0, "delta": 0.0})
    return {
        "schema": COMPARE_SCHEMA,
        "generated_at": _iso_utc(),
        "status": status,
        "headline": {
            "metric": "score",
            "baseline": score.get("baseline", 0.0),
            "candidate": score.get("candidate", 0.0),
            "delta": score.get("delta", 0.0),
            "delta_pct_points": score.get("delta_pct_points", round(_num(score.get("delta")) * 100, 3)),
            "relative_improvement_pct": score.get("relative_improvement_pct"),
        },
        "baseline": {
            "run_id": baseline.get("run_id"),
            "suite": baseline.get("suite"),
            "commit": baseline.get("commit"),
        },
        "candidate": {
            "run_id": candidate.get("run_id"),
            "suite": candidate.get("suite"),
            "commit": candidate.get("commit"),
        },
        "metrics": metrics,
        "quality_regressions": regressions,
        "quality_improvements": improvements,
    }


def gate_decision(compare: dict[str, Any], gate: dict[str, Any] | None = None) -> dict[str, Any]:
    gate = gate or {}
    failures = list(_list(compare.get("quality_regressions")))
    metrics = _dict(compare.get("metrics"))
    false_success_delta = _num(_dict(metrics.get("false_success")).get("delta"))
    max_false_success_delta = _num(gate.get("max_false_success_delta"))
    if false_success_delta > max_false_success_delta and "false_success" not in failures:
        failures.append("false_success")
    max_cost_delta = gate.get("max_cost_delta")
    if isinstance(max_cost_delta, (int, float)):
        if _num(_dict(metrics.get("cost_usd")).get("delta")) > float(max_cost_delta):
            failures.append("cost_usd")
    max_duration_ms_delta = gate.get("max_duration_ms_delta")
    if isinstance(max_duration_ms_delta, (int, float)):
        if _num(_dict(metrics.get("duration_ms")).get("delta")) > float(max_duration_ms_delta):
            failures.append("duration_ms")
    allow_neutral = bool(gate.get("allow_neutral", True))
    if not allow_neutral and not compare.get("quality_improvements") and not failures:
        failures.append("neutral_candidate")
    return {
        "schema": "legion.bench.gate.v1",
        "generated_at": _iso_utc(),
        "status": "pass" if not failures else "fail",
        "failures": sorted(set(failures)),
        "compare": compare,
    }


def _run_json_command(
    argv: list[str],
    *,
    cwd: str,
    env: dict[str, str],
    timeout: int = 120,
) -> dict[str, Any]:
    start = time.monotonic()
    try:
        proc = subprocess.run(
            argv,
            cwd=cwd,
            env=env,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            timeout=timeout,
        )
    except (OSError, subprocess.TimeoutExpired) as exc:
        return {
            "ok": False,
            "cmd": argv,
            "returncode": None,
            "duration_ms": int((time.monotonic() - start) * 1000),
            "stdout": "",
            "stderr": "",
            "json": None,
            "error": str(exc),
        }
    try:
        payload = json.loads(proc.stdout)
    except ValueError:
        payload = None
    return {
        "ok": proc.returncode == 0,
        "cmd": argv,
        "returncode": proc.returncode,
        "duration_ms": int((time.monotonic() - start) * 1000),
        "stdout": proc.stdout[-4000:],
        "stderr": proc.stderr[-4000:],
        "json": payload,
    }


def _learning_case_result(
    case_id: str,
    *,
    ok: bool,
    summary: str,
    reason: str,
    details: dict[str, Any],
) -> dict[str, Any]:
    return {
        "schema": CASE_RESULT_SCHEMA,
        "id": case_id,
        "type": "learning",
        "required": True,
        "status": "pass" if ok else "fail",
        "ok": ok,
        "started_at": _iso_utc(),
        "duration_ms": int(details.get("duration_ms") or 0),
        "target_type": "plugin",
        "target_name": "legion-observability",
        "summary": summary,
        "reason": reason,
        "false_success": False,
        "metrics": {"learning_pass": 1 if ok else 0},
        "details": details,
    }


def _write_learning_session(home: str, correction: str) -> str:
    path = os.path.join(home, ".codex", "sessions", "legion", "session.jsonl")
    os.makedirs(os.path.dirname(path), exist_ok=True)
    payload = {"payload": {"type": "user_message", "content": correction}}
    with open(path, "w", encoding="utf-8") as handle:
        handle.write(json.dumps(payload, sort_keys=True))
        handle.write("\n")
    return path


def _learning_probe_results(repo: str, home: str, logs: str, env: dict[str, str]) -> list[dict[str, Any]]:
    session_learn = os.path.join(repo, "legion-observability", "bin", "legion-session-learn")
    self_learn = os.path.join(repo, "legion-observability", "bin", "legion-self-learn")
    scan = _run_json_command(
        [
            session_learn,
            "--home",
            home,
            "--logs",
            logs,
            "--lookback-days",
            "30",
            "--json",
        ],
        cwd=repo,
        env=env,
    )
    scan_ok = scan.get("ok") and _json_path(scan.get("json"), "candidates.0.category") == (
        "user-correction-feedback"
    )
    outcomes = os.path.join(logs, "self-learn", "outcomes.jsonl")
    outcome_ok = _validate_jsonl_contains(
        outcomes,
        {
            "source": "session-learn",
            "target_type": "plugin",
            "target_name": "legion-observability",
            "metadata": {"category": "user-correction-feedback"},
        },
    )
    memory = os.path.join(logs, "self-learn", "harness-memory.json")
    try:
        memory_ok = _json_path(
            _json_file(memory),
            "entities.plugin:legion-observability.target_name",
        ) == "legion-observability"
    except ValueError:
        memory_ok = False
    hints = _run_json_command(
        [
            self_learn,
            "hints",
            "--logs",
            logs,
            "--entity",
            "plugin:legion-observability",
            "--json",
        ],
        cwd=repo,
        env=env,
    )
    hints_ok = hints.get("ok") and _json_path(
        hints.get("json"),
        "entities.plugin:legion-observability.target_name",
    ) == "legion-observability"
    return [
        _learning_case_result(
            "learning.scan-user-correction",
            ok=bool(scan_ok),
            summary="Session scan should classify the correction.",
            reason="classified user correction" if scan_ok else "missing user-correction-feedback candidate",
            details=scan,
        ),
        _learning_case_result(
            "learning.recorded-outcome",
            ok=outcome_ok,
            summary="Learning should record the correction as an outcome.",
            reason="outcome recorded" if outcome_ok else "no recorded session-learn outcome",
            details={"path": outcomes},
        ),
        _learning_case_result(
            "learning.memory-entity",
            ok=memory_ok,
            summary="Self-learning should synthesize durable memory for the entity.",
            reason="memory entity present" if memory_ok else "memory entity missing",
            details={"path": memory},
        ),
        _learning_case_result(
            "learning.hints-entity",
            ok=bool(hints_ok),
            summary="Hints should expose the learned correction guardrail.",
            reason="hint entity present" if hints_ok else "hint entity missing",
            details=hints,
        ),
    ]


def learning_lift_payload(args: argparse.Namespace) -> dict[str, Any]:
    repo = os.path.abspath(args.repo)
    bench_dir = os.path.abspath(os.path.expanduser(args.bench_dir))
    run_id = args.run_id or _run_id("learning-lift")
    workspace = os.path.join(bench_dir, "runs", run_id, "learning-workspace")
    home = os.path.join(workspace, "home")
    logs = os.path.abspath(os.path.expanduser(args.logs)) if args.logs else os.path.join(workspace, "logs")
    os.makedirs(home, exist_ok=True)
    os.makedirs(logs, exist_ok=True)
    session_path = _write_learning_session(home, args.correction)
    env = os.environ.copy()
    env.update({
        "HOME": home,
        "LEGION_TELEMETRY_DIR": os.path.join(logs, "spans"),
        "PYTHONUNBUFFERED": "1",
    })
    suite = {
        "schema": SUITE_SCHEMA,
        "suite": "learning-lift",
        "description": "Synthetic before/after fixture for session self-learning lift.",
        "gate": {"allow_neutral": False, "max_false_success_delta": 0},
        "_path": "",
    }
    baseline_start = time.monotonic()
    baseline_results = _learning_probe_results(repo, home, logs, env)
    baseline_summary = summarize_run(
        suite,
        baseline_results,
        run_id=f"{run_id}-baseline",
        repo=repo,
        duration_ms=int((time.monotonic() - baseline_start) * 1000),
    )
    baseline_artifacts = write_run_artifacts(
        bench_dir,
        f"{run_id}-baseline",
        suite,
        baseline_results,
        baseline_summary,
    )

    session_learn = os.path.join(repo, "legion-observability", "bin", "legion-session-learn")
    self_learn = os.path.join(repo, "legion-observability", "bin", "legion-self-learn")
    train = [
        _run_json_command(
            [
                session_learn,
                "--home",
                home,
                "--logs",
                logs,
                "--lookback-days",
                "30",
                "--record",
                "--json",
            ],
            cwd=repo,
            env=env,
        ),
        _run_json_command(
            [
                self_learn,
                "run",
                "--repo",
                repo,
                "--logs",
                logs,
                "--apply-memory",
                "--json",
            ],
            cwd=repo,
            env=env,
        ),
    ]

    candidate_start = time.monotonic()
    candidate_results = _learning_probe_results(repo, home, logs, env)
    candidate_summary = summarize_run(
        suite,
        candidate_results,
        run_id=f"{run_id}-candidate",
        repo=repo,
        duration_ms=int((time.monotonic() - candidate_start) * 1000),
    )
    candidate_artifacts = write_run_artifacts(
        bench_dir,
        f"{run_id}-candidate",
        suite,
        candidate_results,
        candidate_summary,
    )
    telemetry_dir = args.telemetry_dir or os.environ.get("LEGION_TELEMETRY_DIR") or os.path.join(
        logs,
        "spans",
    )
    span_path = emit_bench_span(candidate_summary, candidate_artifacts, telemetry_dir)
    comparison = compare_summaries(baseline_summary, candidate_summary)
    baseline_metrics = _dict(baseline_summary.get("metrics"))
    candidate_metrics = _dict(candidate_summary.get("metrics"))
    cases = int(candidate_metrics.get("learning_cases") or 0)
    lift = {
        "headline_metric": "delta_pct_points",
        "baseline_pass": int(baseline_metrics.get("learning_pass") or 0),
        "candidate_pass": int(candidate_metrics.get("learning_pass") or 0),
        "cases": cases,
        "baseline_score": baseline_metrics.get("score", 0.0),
        "candidate_score": candidate_metrics.get("score", 0.0),
        "delta_pct_points": _dict(comparison.get("headline")).get("delta_pct_points"),
        "relative_improvement_pct": _dict(comparison.get("headline")).get("relative_improvement_pct"),
        "relative_lift_reliable": cases >= 30,
        "note": (
            "Use percentage-point lift as the headline for this small deterministic fixture; "
            "relative lift is denominator-sensitive until the corpus has at least 30 cases."
        ),
    }
    return {
        "schema": "legion.bench.learning-lift.v1",
        "run_id": run_id,
        "workspace": workspace,
        "home": home,
        "logs": logs,
        "session_path": session_path,
        "baseline": {
            "summary": baseline_summary,
            "artifacts": baseline_artifacts,
            "cases": baseline_results,
        },
        "train": train,
        "candidate": {
            "summary": candidate_summary,
            "artifacts": candidate_artifacts,
            "cases": candidate_results,
        },
        "comparison": comparison,
        "learning_lift": lift,
        "span_path": span_path,
    }


def learning_lift_command(args: argparse.Namespace) -> int:
    payload = learning_lift_payload(args)
    comparison = _dict(payload.get("comparison"))
    headline = _dict(comparison.get("headline"))
    if args.json:
        print(json.dumps(payload, indent=2, sort_keys=True))
    else:
        lift = _dict(payload.get("learning_lift"))
        print(
            "legion-bench learning-lift: "
            f"{int(lift.get('baseline_pass') or 0)}/{int(lift.get('cases') or 0)} -> "
            f"{int(lift.get('candidate_pass') or 0)}/{int(lift.get('cases') or 0)} "
            f"({float(lift.get('delta_pct_points') or 0):+g} pp)"
        )
        if not lift.get("relative_lift_reliable"):
            print("relative lift: suppressed for small synthetic fixture")
        print(f"baseline: {payload['baseline']['artifacts']['run_path']}")
        print(f"candidate: {payload['candidate']['artifacts']['run_path']}")
    if args.strict:
        candidate_ok = bool(_dict(payload.get("candidate")).get("summary", {}).get("ok"))
        improved = comparison.get("status") == "improved"
        if not candidate_ok or not improved:
            return 1
    return 0


def _run_suite_artifacts(
    *,
    repo: str,
    suite: dict[str, Any],
    bench_dir: str,
    run_id: str,
) -> dict[str, Any]:
    run_dir = os.path.join(os.path.abspath(os.path.expanduser(bench_dir)), "runs", run_id)
    start = time.monotonic()
    results = [run_case(case, repo, run_dir) for case in _list(suite.get("cases"))]
    duration_ms = int((time.monotonic() - start) * 1000)
    summary = summarize_run(suite, results, run_id=run_id, repo=repo, duration_ms=duration_ms)
    artifacts = write_run_artifacts(bench_dir, run_id, suite, results, summary)
    return {"results": results, "summary": summary, "artifacts": artifacts}


def stability_rollup(
    suite: dict[str, Any],
    iterations: list[dict[str, Any]],
    *,
    run_id: str,
    repo: str,
) -> dict[str, Any]:
    summaries = [_dict(item.get("summary")) for item in iterations]
    scores = [_metric(summary, "score") for summary in summaries]
    pass_rates = [_metric(summary, "pass_rate") for summary in summaries]
    required_fails = [_metric(summary, "required_fail") for summary in summaries]
    case_statuses: dict[str, list[str]] = {}
    case_dimensions: dict[str, str] = {}
    for item in iterations:
        for result in _list(item.get("results")):
            case_id = _text(result.get("id"))
            if not case_id:
                continue
            case_statuses.setdefault(case_id, []).append(_text(result.get("status")) or "unknown")
            case_dimensions.setdefault(case_id, _text(result.get("dimension")) or "uncategorized")
    flake_cases = [
        {
            "id": case_id,
            "dimension": case_dimensions.get(case_id, "uncategorized"),
            "statuses": statuses,
        }
        for case_id, statuses in sorted(case_statuses.items())
        if len(set(statuses)) > 1
    ]
    dimensions: dict[str, dict[str, Any]] = {}
    for item in iterations:
        for dimension, summary in _dict(_dict(item.get("summary")).get("dimensions")).items():
            entry = dimensions.setdefault(
                dimension,
                {
                    "case_runs": 0,
                    "pass": 0,
                    "fail": 0,
                    "required_fail": 0,
                },
            )
            dim = _dict(summary)
            entry["case_runs"] += int(dim.get("cases") or 0)
            entry["pass"] += int(dim.get("pass") or 0)
            entry["fail"] += int(dim.get("fail") or 0)
            entry["required_fail"] += int(dim.get("required_fail") or 0)
    for entry in dimensions.values():
        entry["pass_rate"] = _rate(int(entry["pass"]), int(entry["case_runs"]))
    metrics = {
        "iterations": len(iterations),
        "cases_per_iteration": int(_metric(summaries[0], "cases")) if summaries else 0,
        "total_case_runs": sum(int(_metric(summary, "cases")) for summary in summaries),
        "mean_score": round(sum(scores) / len(scores), 6) if scores else 0.0,
        "min_score": min(scores) if scores else 0.0,
        "max_score": max(scores) if scores else 0.0,
        "mean_pass_rate": round(sum(pass_rates) / len(pass_rates), 6) if pass_rates else 0.0,
        "min_pass_rate": min(pass_rates) if pass_rates else 0.0,
        "max_pass_rate": max(pass_rates) if pass_rates else 0.0,
        "required_fail_total": int(sum(required_fails)),
        "flake_count": len(flake_cases),
    }
    stable_pass = metrics["required_fail_total"] == 0 and metrics["flake_count"] == 0
    return {
        "schema": "legion.bench.stability.v1",
        "generated_at": _iso_utc(),
        "run_id": run_id,
        "suite": suite.get("suite"),
        "repo": os.path.abspath(repo),
        "commit": _git_commit(repo),
        "ok": stable_pass,
        "metrics": metrics,
        "dimensions": dict(sorted(dimensions.items())),
        "flake_cases": flake_cases,
        "iterations": [
            {
                "run_id": _dict(item.get("summary")).get("run_id"),
                "summary_path": _dict(item.get("artifacts")).get("summary_path"),
                "run_path": _dict(item.get("artifacts")).get("run_path"),
                "score": _metric(_dict(item.get("summary")), "score"),
                "pass_rate": _metric(_dict(item.get("summary")), "pass_rate"),
                "required_fail": _metric(_dict(item.get("summary")), "required_fail"),
            }
            for item in iterations
        ],
    }


def write_stability_artifact(bench_dir: str, run_id: str, payload: dict[str, Any]) -> dict[str, str]:
    root = os.path.abspath(os.path.expanduser(bench_dir))
    path = os.path.join(root, "stability", f"{run_id}.json")
    latest_path = os.path.join(root, "stability", "latest.json")
    _write_json(path, payload)
    _write_json(
        latest_path,
        {
            "schema": "legion.bench.stability-latest.v1",
            "run_id": run_id,
            "suite": payload.get("suite"),
            "path": path,
            "generated_at": payload.get("generated_at"),
        },
    )
    return {"stability_path": path, "latest_stability_path": latest_path}


def _command_sequence(value: Any) -> list[Any]:
    if value in (None, "", []):
        return []
    if isinstance(value, list):
        if all(isinstance(item, str) for item in value):
            return [value]
        return value
    return [value]


def _mode_by_id(corpus: dict[str, Any]) -> dict[str, dict[str, Any]]:
    return {
        _text(_dict(mode).get("id")): _dict(mode)
        for mode in _list(corpus.get("modes"))
        if _text(_dict(mode).get("id"))
    }


def _selected_corpus_modes(corpus: dict[str, Any], requested: list[str]) -> list[dict[str, Any]]:
    modes = _mode_by_id(corpus)
    if not requested:
        default_modes = [_text(mode_id) for mode_id in _list(corpus.get("default_modes")) if _text(mode_id)]
        if default_modes:
            missing_defaults = [mode_id for mode_id in default_modes if mode_id not in modes]
            if missing_defaults:
                raise ValueError(f"unknown default corpus mode(s): {', '.join(missing_defaults)}")
            return [modes[mode_id] for mode_id in default_modes]
        return [modes[_text(_dict(mode).get("id"))] for mode in _list(corpus.get("modes"))]
    missing = [mode_id for mode_id in requested if mode_id not in modes]
    if missing:
        raise ValueError(f"unknown corpus mode(s): {', '.join(missing)}")
    return [modes[mode_id] for mode_id in requested]


def _case_mode_command(case: dict[str, Any], mode: dict[str, Any]) -> Any:
    mode_id = _text(mode.get("id"))
    commands = _dict(case.get("commands"))
    if mode_id in commands:
        return commands[mode_id]
    if case.get("command"):
        return case.get("command")
    if mode.get("command"):
        return mode.get("command")
    raise ValueError(f"case {case.get('id')} has no command for mode {mode_id}")


def _case_mode_expected_exit(case: dict[str, Any], mode: dict[str, Any]) -> int:
    mode_id = _text(mode.get("id"))
    by_mode = _dict(case.get("expect_exit_by_mode"))
    if mode_id in by_mode:
        return int(by_mode[mode_id])
    if case.get("expect_exit") is not None:
        return int(case.get("expect_exit"))
    if mode.get("expect_exit") is not None:
        return int(mode.get("expect_exit"))
    return 0


def _case_mode_validators(case: dict[str, Any], mode: dict[str, Any]) -> list[Any]:
    mode_id = _text(mode.get("id"))
    validators = []
    validators.extend(_list(case.get("validators")))
    validators.extend(_list(_dict(case.get("validators_by_mode")).get(mode_id)))
    validators.extend(_list(mode.get("validators")))
    return validators


def _mean(values: list[int]) -> float:
    return round(sum(values) / len(values), 3) if values else 0.0


def _percentile(values: list[int], percentile: float) -> int:
    if not values:
        return 0
    ordered = sorted(values)
    if len(ordered) == 1:
        return int(ordered[0])
    rank = (len(ordered) - 1) * (percentile / 100.0)
    lower = math.floor(rank)
    upper = math.ceil(rank)
    if lower == upper:
        return int(ordered[lower])
    weight = rank - lower
    return int(round(ordered[lower] * (1 - weight) + ordered[upper] * weight))


def _wilson_interval(successes: int, total: int, z: float = 1.959963984540054) -> dict[str, float | None]:
    if total <= 0:
        return {"low": None, "high": None}
    phat = successes / total
    denominator = 1 + z * z / total
    center = (phat + z * z / (2 * total)) / denominator
    margin = z * math.sqrt((phat * (1 - phat) + z * z / (4 * total)) / total) / denominator
    return {
        "low": round(max(0.0, center - margin), 6),
        "high": round(min(1.0, center + margin), 6),
    }


def _mcnemar_exact_p_value(baseline_only_pass: int, candidate_only_pass: int) -> float | None:
    discordant = baseline_only_pass + candidate_only_pass
    if discordant == 0:
        return None
    smaller = min(baseline_only_pass, candidate_only_pass)
    tail = sum(math.comb(discordant, index) for index in range(smaller + 1)) * (0.5 ** discordant)
    return round(min(1.0, 2 * tail), 12)


def _corpus_case_key(result: dict[str, Any]) -> tuple[str, int]:
    return _text(result.get("id")), int(result.get("attempt") or 1)


def _paired_mode_comparison(
    results: list[dict[str, Any]],
    *,
    baseline_mode: str,
    candidate_mode: str,
) -> dict[str, Any]:
    baseline = {
        _corpus_case_key(result): result
        for result in results
        if _text(result.get("mode")) == baseline_mode
    }
    candidate = {
        _corpus_case_key(result): result
        for result in results
        if _text(result.get("mode")) == candidate_mode
    }
    keys = sorted(set(baseline) & set(candidate))
    both_pass = both_fail = baseline_only_pass = candidate_only_pass = 0
    candidate_wins: list[str] = []
    baseline_wins: list[str] = []
    for key in keys:
        base_ok = baseline[key].get("status") == "pass"
        cand_ok = candidate[key].get("status") == "pass"
        case_label = f"{key[0]}#{key[1]}"
        if base_ok and cand_ok:
            both_pass += 1
        elif not base_ok and not cand_ok:
            both_fail += 1
        elif base_ok:
            baseline_only_pass += 1
            baseline_wins.append(case_label)
        else:
            candidate_only_pass += 1
            candidate_wins.append(case_label)
    p_value = _mcnemar_exact_p_value(baseline_only_pass, candidate_only_pass)
    discordant = baseline_only_pass + candidate_only_pass
    return {
        "paired_case_runs": len(keys),
        "both_pass": both_pass,
        "both_fail": both_fail,
        "baseline_only_pass": baseline_only_pass,
        "candidate_only_pass": candidate_only_pass,
        "net_candidate_wins": candidate_only_pass - baseline_only_pass,
        "discordant": discordant,
        "candidate_win_rate_on_discordant": _rate(candidate_only_pass, discordant),
        "mcnemar_exact_p_value": p_value,
        "significant_95": bool(p_value is not None and p_value < 0.05),
        "candidate_wins": candidate_wins[:25],
        "baseline_wins": baseline_wins[:25],
    }


def _failure_clusters(results: list[dict[str, Any]], limit: int = 12) -> list[dict[str, Any]]:
    clusters: dict[tuple[str, str, str], dict[str, Any]] = {}
    for result in results:
        if result.get("status") == "pass":
            continue
        reason = _text(result.get("reason")) or "unknown"
        # Keep validator counts stable across paths by removing long stdout/stderr fragments.
        reason = reason.split("; stdout=", 1)[0]
        key = (_text(result.get("mode")), _text(result.get("dimension")) or "corpus", reason)
        entry = clusters.setdefault(
            key,
            {
                "mode": key[0],
                "dimension": key[1],
                "reason": key[2],
                "count": 0,
                "cases": [],
            },
        )
        entry["count"] += 1
        if len(entry["cases"]) < 10:
            entry["cases"].append(_text(result.get("id")))
    return sorted(clusters.values(), key=lambda item: (-int(item["count"]), item["mode"], item["dimension"]))[:limit]


def run_corpus_case_mode(
    case: dict[str, Any],
    mode: dict[str, Any],
    *,
    repo: str,
    run_dir: str,
    repeat_index: int,
) -> dict[str, Any]:
    case_id = _text(case.get("id")) or _stable_id([case])
    mode_id = _text(mode.get("id"))
    safe_case_id = "".join(ch if ch.isalnum() or ch in "._-" else "-" for ch in case_id)
    safe_mode_id = "".join(ch if ch.isalnum() or ch in "._-" else "-" for ch in mode_id)
    workspace = os.path.join(run_dir, "corpus-workspaces", safe_mode_id, f"attempt-{repeat_index:02d}", safe_case_id)
    home = os.path.join(workspace, "home")
    logs = os.path.join(workspace, "logs")
    os.makedirs(home, exist_ok=True)
    os.makedirs(logs, exist_ok=True)
    task = _text(case.get("task")) or _text(case.get("prompt")) or _text(case.get("summary"))
    task_file = os.path.join(workspace, "task.txt")
    # The rendered case carries answer_files. Keep it OUT of the agent workspace
    # so live modes cannot read the reference solution from case.json; the
    # scripted fixture-agent reads it via LEGION_BENCH_CASE_FILE (set below).
    case_dir = os.path.join(run_dir, "case-data", safe_mode_id, f"attempt-{repeat_index:02d}")
    os.makedirs(case_dir, exist_ok=True)
    case_file = os.path.join(case_dir, f"{safe_case_id}.json")
    context = {
        "repo": os.path.abspath(repo),
        "workspace": workspace,
        "home": home,
        "logs": logs,
        "case_id": case_id,
        "mode_id": mode_id,
        "run_dir": run_dir,
        "task": task,
        "task_file": task_file,
        "case_file": case_file,
        "attempt": str(repeat_index),
    }
    _write_fixture_files(workspace, _dict(case.get("files")), context)
    with open(task_file, "w", encoding="utf-8") as handle:
        handle.write(task)
        handle.write("\n")
    _write_json(case_file, _dict(_render(case, context)))

    env = os.environ.copy()
    real_home = env.get("HOME", "")
    env.update({
        "HOME": home,
        "LEGION_TELEMETRY_DIR": os.path.join(logs, "spans"),
        "LEGION_BENCH_REPO": os.path.abspath(repo),
        "LEGION_BENCH_WORKSPACE": workspace,
        "LEGION_BENCH_HOME": home,
        "LEGION_BENCH_REAL_HOME": real_home,
        "LEGION_BENCH_LOGS": logs,
        "LEGION_BENCH_CASE_ID": case_id,
        "LEGION_BENCH_MODE_ID": mode_id,
        "LEGION_BENCH_TASK_FILE": task_file,
        "LEGION_BENCH_CASE_FILE": case_file,
        "PYTHONUNBUFFERED": "1",
    })
    env.update({key: str(value) for key, value in _dict(_render(mode.get("env"), context)).items()})
    env.update({key: str(value) for key, value in _dict(_render(case.get("env"), context)).items()})
    cwd = _text(_render(case.get("cwd") or mode.get("cwd") or "{workspace}", context))
    timeout = int(case.get("timeout") or mode.get("timeout") or 300)
    setup_results = []
    for command in _command_sequence(mode.get("setup")) + _command_sequence(case.get("setup")):
        result = _run_process_command(command, context=context, cwd=cwd, env=env, timeout=timeout)
        setup_results.append(result)
        if result.get("returncode") != 0:
            spans = _span_totals(logs)
            return {
                "schema": "legion.bench.corpus-case-result.v1",
                "id": case_id,
                "mode": mode_id,
                "attempt": repeat_index,
                "status": "fail",
                "ok": False,
                "required": bool(case.get("required", True)),
                "dimension": _text(case.get("dimension")) or "corpus",
                "summary": _text(case.get("summary")),
                "reason": f"setup exited {result.get('returncode')}",
                "metrics": {
                    "duration_ms": int(result.get("duration_ms") or 0),
                    **spans,
                },
                "details": {
                    "workspace": workspace,
                    "logs": logs,
                    "task_file": task_file,
                    "case_file": case_file,
                    "setup": setup_results,
                    "stdout": _short(_text(result.get("stdout")), 4000),
                    "stderr": _short(_text(result.get("stderr")), 4000),
                },
            }

    command_result = _run_process_command(
        _case_mode_command(case, mode),
        context=context,
        cwd=cwd,
        env=env,
        timeout=timeout,
    )
    provider_block_reason = _provider_block_reason(command_result)
    if provider_block_reason:
        spans = _span_totals(logs)
        duration_ms = int(command_result.get("duration_ms") or 0) + sum(
            int(result.get("duration_ms") or 0) for result in setup_results
        )
        return {
            "schema": "legion.bench.corpus-case-result.v1",
            "id": case_id,
            "mode": mode_id,
            "attempt": repeat_index,
            "status": "blocked",
            "ok": False,
            "required": bool(case.get("required", True)),
            "dimension": _text(case.get("dimension")) or "corpus",
            "summary": _text(case.get("summary")),
            "reason": provider_block_reason,
            "metrics": {
                "duration_ms": duration_ms,
                **spans,
            },
            "details": {
                "workspace": workspace,
                "logs": logs,
                "task": task,
                "task_file": task_file,
                "case_file": case_file,
                "setup": setup_results,
                "cmd": command_result.get("cmd"),
                "cwd": cwd,
                "returncode": command_result.get("returncode"),
                "expected_exit": _case_mode_expected_exit(case, mode),
                "validators": [],
                "provider_blocked": True,
                "provider_block_reason": provider_block_reason,
                "stdout": _short(_text(command_result.get("stdout")), 4000),
                "stderr": _short(_text(command_result.get("stderr")), 4000),
            },
        }
    expected_exit = _case_mode_expected_exit(case, mode)
    validator_results = run_task_validators(
        _case_mode_validators(case, mode),
        context=context,
        stdout=_text(command_result.get("stdout")),
        stderr=_text(command_result.get("stderr")),
        env=env,
    )
    exit_ok = command_result.get("returncode") == expected_exit
    validators_ok = all(result.get("ok") for result in validator_results)
    ok = exit_ok and validators_ok
    spans = _span_totals(logs)
    duration_ms = int(command_result.get("duration_ms") or 0) + sum(
        int(result.get("duration_ms") or 0) for result in setup_results
    )
    return {
        "schema": "legion.bench.corpus-case-result.v1",
        "id": case_id,
        "mode": mode_id,
        "attempt": repeat_index,
        "status": "pass" if ok else "fail",
        "ok": ok,
        "required": bool(case.get("required", True)),
        "dimension": _text(case.get("dimension")) or "corpus",
        "summary": _text(case.get("summary")),
        "reason": "case passed" if ok else (
            f"exit={command_result.get('returncode')} expected={expected_exit}; "
            f"validators={sum(1 for item in validator_results if item.get('ok'))}/{len(validator_results)}"
        ),
        "metrics": {
            "duration_ms": duration_ms,
            **spans,
        },
        "details": {
            "workspace": workspace,
            "logs": logs,
            "task": task,
            "task_file": task_file,
            "case_file": case_file,
            "setup": setup_results,
            "cmd": command_result.get("cmd"),
            "cwd": cwd,
            "returncode": command_result.get("returncode"),
            "expected_exit": expected_exit,
            "validators": validator_results,
            "stdout": _short(_text(command_result.get("stdout")), 4000),
            "stderr": _short(_text(command_result.get("stderr")), 4000),
        },
    }


def _summarize_corpus_mode(results: list[dict[str, Any]]) -> dict[str, Any]:
    case_runs = len(results)
    passed = sum(1 for result in results if result.get("status") == "pass")
    blocked = sum(1 for result in results if result.get("status") == "blocked")
    required = [result for result in results if result.get("required")]
    required_pass = sum(1 for result in required if result.get("status") == "pass")
    required_blocked = sum(1 for result in required if result.get("status") == "blocked")
    durations = [int(_dict(result.get("metrics")).get("duration_ms") or 0) for result in results]
    dimensions: dict[str, dict[str, Any]] = {}
    models: dict[str, dict[str, Any]] = {}
    for result in results:
        result_metrics = _dict(result.get("metrics"))
        dimension = _text(result.get("dimension")) or "corpus"
        entry = dimensions.setdefault(dimension, {"case_runs": 0, "pass": 0, "fail": 0, "blocked": 0})
        entry["case_runs"] += 1
        if result.get("status") == "pass":
            entry["pass"] += 1
        elif result.get("status") == "blocked":
            entry["blocked"] += 1
            entry["fail"] += 1
        else:
            entry["fail"] += 1
        for model, model_metrics_raw in _dict(result_metrics.get("models")).items():
            model_name = _text(model) or "unknown"
            model_metrics = _dict(model_metrics_raw)
            model_entry = models.setdefault(
                model_name,
                {"span_count": 0, "cost_usd": 0.0, "span_duration_ms": 0, "tokens": 0},
            )
            model_entry["span_count"] += int(model_metrics.get("span_count") or 0)
            model_entry["cost_usd"] = round(
                float(model_entry["cost_usd"]) + _num(model_metrics.get("cost_usd")),
                6,
            )
            model_entry["span_duration_ms"] += int(_num(model_metrics.get("span_duration_ms")))
            model_entry["tokens"] += int(_num(model_metrics.get("tokens")))
    for entry in dimensions.values():
        entry["pass_rate"] = _rate(int(entry["pass"]), int(entry["case_runs"]))
    metrics = {
        "case_runs": case_runs,
        "pass": passed,
        "fail": case_runs - passed,
        "blocked": blocked,
        "pass_rate": _rate(passed, case_runs),
        "pass_rate_ci95": _wilson_interval(passed, case_runs),
        "required_case_runs": len(required),
        "required_pass": required_pass,
        "required_fail": len(required) - required_pass,
        "required_blocked": required_blocked,
        "required_pass_rate": _rate(required_pass, len(required)),
        "required_pass_rate_ci95": _wilson_interval(required_pass, len(required)),
        "duration_ms": sum(int(_dict(result.get("metrics")).get("duration_ms") or 0) for result in results),
        "mean_duration_ms": _mean(durations),
        "p95_duration_ms": _percentile(durations, 95),
        "cost_usd": round(sum(float(_dict(result.get("metrics")).get("cost_usd") or 0.0) for result in results), 6),
        "tokens": sum(int(_dict(result.get("metrics")).get("tokens") or 0) for result in results),
        "span_count": sum(int(_dict(result.get("metrics")).get("span_count") or 0) for result in results),
        "models": dict(sorted(models.items())),
    }
    return {"metrics": metrics, "dimensions": dict(sorted(dimensions.items()))}


def summarize_corpus_run(
    corpus: dict[str, Any],
    results: list[dict[str, Any]],
    *,
    run_id: str,
    repo: str,
    baseline_mode: str,
    reliability_min_cases: int,
) -> dict[str, Any]:
    by_mode: dict[str, list[dict[str, Any]]] = {}
    for result in results:
        by_mode.setdefault(_text(result.get("mode")), []).append(result)
    modes = {mode_id: _summarize_corpus_mode(items) for mode_id, items in sorted(by_mode.items())}
    configured_clean_modes = [
        mode_id
        for mode_id in (_text(item) for item in _list(corpus.get("required_clean_modes")))
        if mode_id
    ]
    required_clean_modes = [mode_id for mode_id in configured_clean_modes if mode_id in modes]
    if required_clean_modes:
        ok = all(
            int(_dict(_dict(modes[mode_id]).get("metrics")).get("required_fail") or 0) == 0
            for mode_id in required_clean_modes
        )
    elif configured_clean_modes:
        ok = True
    else:
        ok = all(_dict(summary.get("metrics")).get("required_fail") == 0 for summary in modes.values())
    comparisons: dict[str, dict[str, Any]] = {}
    baseline = _dict(_dict(modes.get(baseline_mode)).get("metrics"))
    for mode_id, summary in modes.items():
        if mode_id == baseline_mode:
            continue
        candidate = _dict(summary.get("metrics"))
        baseline_rate = _num(baseline.get("pass_rate"))
        candidate_rate = _num(candidate.get("pass_rate"))
        case_runs = min(int(baseline.get("case_runs") or 0), int(candidate.get("case_runs") or 0))
        delta = round(candidate_rate - baseline_rate, 6)
        paired = _paired_mode_comparison(
            results,
            baseline_mode=baseline_mode,
            candidate_mode=mode_id,
        )
        comparisons[f"{baseline_mode}..{mode_id}"] = {
            "baseline": baseline_mode,
            "candidate": mode_id,
            "metric": "pass_rate",
            "baseline_pass_rate": baseline_rate,
            "candidate_pass_rate": candidate_rate,
            "delta": delta,
            "delta_pct_points": round(delta * 100, 3),
            "relative_improvement_pct": _relative_delta_pct(baseline_rate, candidate_rate),
            "case_runs": case_runs,
            "reliable": case_runs >= reliability_min_cases,
            "reliability_min_cases": reliability_min_cases,
            "paired": paired,
            "cost_usd_delta": round(float(candidate.get("cost_usd") or 0.0) - float(baseline.get("cost_usd") or 0.0), 6),
            "duration_ms_delta": int(candidate.get("duration_ms") or 0) - int(baseline.get("duration_ms") or 0),
            "tokens_delta": int(candidate.get("tokens") or 0) - int(baseline.get("tokens") or 0),
        }
    return {
        "schema": "legion.bench.corpus-summary.v1",
        "generated_at": _iso_utc(),
        "run_id": run_id,
        "corpus": corpus.get("corpus"),
        "repo": os.path.abspath(repo),
        "commit": _git_commit(repo),
        "baseline_mode": baseline_mode,
        "reliability_min_cases": reliability_min_cases,
        "required_clean_modes": required_clean_modes,
        "ok": ok,
        "modes": modes,
        "comparisons": comparisons,
        "failure_clusters": _failure_clusters(results),
    }


def write_corpus_artifacts(
    bench_dir: str,
    run_id: str,
    corpus: dict[str, Any],
    results: list[dict[str, Any]],
    summary: dict[str, Any],
) -> dict[str, str]:
    root = os.path.abspath(os.path.expanduser(bench_dir))
    run_dir = os.path.join(root, "corpus", run_id)
    os.makedirs(run_dir, exist_ok=True)
    cases_path = os.path.join(run_dir, "cases.jsonl")
    summary_path = os.path.join(run_dir, "summary.json")
    run_path = os.path.join(run_dir, "run.json")
    latest_path = os.path.join(root, "corpus", "latest.json")
    with open(cases_path, "w", encoding="utf-8") as handle:
        for result in results:
            handle.write(json.dumps(result, sort_keys=True, ensure_ascii=False))
            handle.write("\n")
    _write_json(summary_path, summary)
    _write_json(
        run_path,
        {
            "schema": "legion.bench.corpus-run.v1",
            "run_id": run_id,
            "generated_at": summary.get("generated_at"),
            "corpus": corpus.get("corpus"),
            "corpus_path": corpus.get("_path"),
            "summary": summary,
            "cases": results,
            "artifacts": {
                "run": run_path,
                "summary": summary_path,
                "cases": cases_path,
            },
        },
    )
    _write_json(
        latest_path,
        {
            "schema": "legion.bench.corpus-latest.v1",
            "run_id": run_id,
            "corpus": corpus.get("corpus"),
            "run_path": run_path,
            "summary_path": summary_path,
            "cases_path": cases_path,
            "generated_at": summary.get("generated_at"),
        },
    )
    return {
        "run_dir": run_dir,
        "run_path": run_path,
        "summary_path": summary_path,
        "cases_path": cases_path,
        "latest_path": latest_path,
    }


def corpus_plan(
    corpus: dict[str, Any],
    modes: list[dict[str, Any]],
    *,
    baseline_mode: str,
    repeat: int,
    reliability_min_cases: int,
) -> dict[str, Any]:
    case_count = len(_list(corpus.get("cases")))
    mode_ids = [_text(mode.get("id")) for mode in modes]
    comparisons = {}
    for mode_id in mode_ids:
        if mode_id == baseline_mode:
            continue
        case_runs = case_count * repeat
        comparisons[f"{baseline_mode}..{mode_id}"] = {
            "baseline": baseline_mode,
            "candidate": mode_id,
            "case_runs": case_runs,
            "reliable": case_runs >= reliability_min_cases,
            "reliability_min_cases": reliability_min_cases,
        }
    live_modes = [
        mode_id
        for mode_id, mode in zip(mode_ids, modes)
        if bool(mode.get("live")) or _text(mode.get("kind")) in {"live", "agent"}
    ]
    return {
        "schema": "legion.bench.corpus-plan.v1",
        "generated_at": _iso_utc(),
        "corpus": corpus.get("corpus"),
        "corpus_path": corpus.get("_path"),
        "description": corpus.get("description"),
        "case_count": case_count,
        "repeat": repeat,
        "mode_count": len(mode_ids),
        "modes": mode_ids,
        "baseline_mode": baseline_mode,
        "case_runs_per_mode": case_count * repeat,
        "total_case_runs": case_count * repeat * len(mode_ids),
        "reliability_min_cases": reliability_min_cases,
        "comparisons": comparisons,
        "has_live_modes_selected": bool(live_modes),
        "live_modes_selected": live_modes,
        "dimensions": dict(sorted({
            _text(_dict(case).get("dimension")) or "corpus": sum(
                1 for item in _list(corpus.get("cases"))
                if (_text(_dict(item).get("dimension")) or "corpus")
                == (_text(_dict(case).get("dimension")) or "corpus")
            )
            for case in _list(corpus.get("cases"))
        }.items())),
    }


def _markdown_float(value: Any, digits: int = 3) -> str:
    if value is None:
        return "n/a"
    try:
        return f"{float(value):.{digits}f}"
    except (TypeError, ValueError):
        return "n/a"


def render_corpus_markdown(summary: dict[str, Any], artifacts: dict[str, str]) -> str:
    lines = [
        f"# Legion Corpus Benchmark: {summary.get('corpus')}",
        "",
        f"- generated: `{summary.get('generated_at')}`",
        f"- run id: `{summary.get('run_id')}`",
        f"- commit: `{summary.get('commit')}`",
        f"- baseline mode: `{summary.get('baseline_mode')}`",
        f"- reliability floor: `{summary.get('reliability_min_cases')}` paired case-runs",
        f"- run artifact: `{artifacts.get('run_path', '')}`",
        "",
        "## Mode Results",
        "",
        "| Mode | Pass | Blocked | Case-runs | Pass rate | 95% CI | Cost | Tokens | Spans | Mean ms | P95 ms |",
        "|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|",
    ]
    for mode_id, mode_summary in _dict(summary.get("modes")).items():
        metrics = _dict(_dict(mode_summary).get("metrics"))
        ci = _dict(metrics.get("pass_rate_ci95"))
        ci_text = f"{_markdown_float(ci.get('low'))}-{_markdown_float(ci.get('high'))}"
        lines.append(
            "| "
            f"`{mode_id}` | "
            f"{int(metrics.get('pass') or 0)} | "
            f"{int(metrics.get('blocked') or 0)} | "
            f"{int(metrics.get('case_runs') or 0)} | "
            f"{_markdown_float(metrics.get('pass_rate'))} | "
            f"{ci_text} | "
            f"${float(metrics.get('cost_usd') or 0):.6f} | "
            f"{int(metrics.get('tokens') or 0)} | "
            f"{int(metrics.get('span_count') or 0)} | "
            f"{_markdown_float(metrics.get('mean_duration_ms'))} | "
            f"{int(metrics.get('p95_duration_ms') or 0)} |"
        )
    lines.extend(["", "## Model Metering", ""])
    model_rows = []
    for mode_id, mode_summary in _dict(summary.get("modes")).items():
        metrics = _dict(_dict(mode_summary).get("metrics"))
        for model, model_metrics in _dict(metrics.get("models")).items():
            model_rows.append((mode_id, _text(model) or "unknown", _dict(model_metrics)))
    if model_rows:
        lines.append("| Mode | Model | Spans | Cost | Tokens | Span ms |")
        lines.append("|---|---|---:|---:|---:|---:|")
        for mode_id, model, model_metrics in model_rows:
            lines.append(
                "| "
                f"`{mode_id}` | "
                f"`{model}` | "
                f"{int(model_metrics.get('span_count') or 0)} | "
                f"${float(model_metrics.get('cost_usd') or 0):.6f} | "
                f"{int(model_metrics.get('tokens') or 0)} | "
                f"{int(model_metrics.get('span_duration_ms') or 0)} |"
            )
    else:
        lines.append("_No model spans recorded._")
    lines.extend(["", "## Comparisons", ""])
    lines.append(
        "| Comparison | Delta pp | Relative | Reliable | Candidate paired wins | Baseline paired wins | McNemar p | Cost delta | Duration delta ms |"
    )
    lines.append("|---|---:|---:|---|---:|---:|---:|---:|---:|")
    for key, comparison in _dict(summary.get("comparisons")).items():
        paired = _dict(comparison.get("paired"))
        relative = comparison.get("relative_improvement_pct")
        relative_text = "n/a" if relative is None else f"{float(relative):+.3f}%"
        p_value = paired.get("mcnemar_exact_p_value")
        lines.append(
            "| "
            f"`{key}` | "
            f"{float(comparison.get('delta_pct_points') or 0):+.3f} | "
            f"{relative_text} | "
            f"{'yes' if comparison.get('reliable') else 'no'} | "
            f"{int(paired.get('candidate_only_pass') or 0)} | "
            f"{int(paired.get('baseline_only_pass') or 0)} | "
            f"{'n/a' if p_value is None else f'{float(p_value):.6f}'} | "
            f"${float(comparison.get('cost_usd_delta') or 0):+.6f} | "
            f"{int(comparison.get('duration_ms_delta') or 0):+d} |"
        )
    clusters = _list(summary.get("failure_clusters"))
    lines.extend(["", "## Failure Clusters", ""])
    if clusters:
        lines.append("| Mode | Dimension | Count | Reason | Example cases |")
        lines.append("|---|---|---:|---|---|")
        for cluster in clusters:
            lines.append(
                "| "
                f"`{cluster.get('mode')}` | "
                f"`{cluster.get('dimension')}` | "
                f"{int(cluster.get('count') or 0)} | "
                f"{_text(cluster.get('reason')).replace('|', '/')} | "
                f"{', '.join(_list(cluster.get('cases')))} |"
            )
    else:
        lines.append("No failures.")
    lines.extend([
        "",
        "## Scope",
        "",
        "This report is generated from a corpus run artifact. Relative lift is only treated as reliable when the selected comparison meets the configured case-run floor.",
        "",
    ])
    return "\n".join(lines)


def corpus_command(args: argparse.Namespace) -> int:
    repo = os.path.abspath(args.repo)
    corpus = load_corpus(repo, args.corpus)
    modes = _selected_corpus_modes(corpus, args.mode or [])
    mode_ids = [_text(mode.get("id")) for mode in modes]
    baseline_mode = args.baseline or _text(corpus.get("baseline")) or mode_ids[0]
    if baseline_mode not in mode_ids:
        raise ValueError(f"baseline mode must be selected: {baseline_mode}")
    reliability_min_cases = int(args.reliability_min_cases or corpus.get("reliability_min_cases") or 30)
    run_id = args.run_id or _run_id(_text(corpus.get("corpus")) or "corpus")
    repeat = max(1, int(args.repeat or 1))
    if args.dry_run:
        payload = corpus_plan(
            corpus,
            modes,
            baseline_mode=baseline_mode,
            repeat=repeat,
            reliability_min_cases=reliability_min_cases,
        )
        if args.json:
            print(json.dumps(payload, indent=2, sort_keys=True))
        else:
            print(f"legion-bench corpus plan: {payload['corpus']}")
            print(f"  modes: {', '.join(mode_ids)}")
            print(f"  cases: {payload['case_count']} x repeat {repeat}")
            print(f"  total case-runs: {payload['total_case_runs']}")
            for key, comparison in _dict(payload.get("comparisons")).items():
                reliable = "reliable" if _dict(comparison).get("reliable") else "small-sample"
                print(f"  {key}: {comparison.get('case_runs')} paired case-runs ({reliable})")
        if args.require_reliable:
            unreliable = [
                key
                for key, comparison in _dict(payload.get("comparisons")).items()
                if not _dict(comparison).get("reliable")
            ]
            if unreliable:
                print(f"legion-bench corpus: unreliable sample size for {', '.join(unreliable)}", file=sys.stderr)
                return 1
        return 0
    run_dir = os.path.join(os.path.abspath(os.path.expanduser(args.bench_dir)), "corpus", run_id)
    results: list[dict[str, Any]] = []
    for mode in modes:
        for attempt in range(1, repeat + 1):
            for case in _list(corpus.get("cases")):
                results.append(
                    run_corpus_case_mode(
                        _dict(case),
                        mode,
                        repo=repo,
                        run_dir=run_dir,
                        repeat_index=attempt,
                    )
                )
    summary = summarize_corpus_run(
        corpus,
        results,
        run_id=run_id,
        repo=repo,
        baseline_mode=baseline_mode,
        reliability_min_cases=reliability_min_cases,
    )
    artifacts = write_corpus_artifacts(args.bench_dir, run_id, corpus, results, summary)
    recorded_outcomes: list[dict[str, Any]] = []
    if getattr(args, "record_failures", False):
        recorded_outcomes = record_failed_corpus_outcomes(
            results,
            log_root=args.logs,
            run_path=artifacts["run_path"],
            run_id=run_id,
            corpus_name=_text(corpus.get("corpus")) or args.corpus,
        )
        artifacts["recorded_outcomes"] = len(recorded_outcomes)
    report_path = ""
    if args.report_md:
        report_path = os.path.abspath(os.path.expanduser(args.report_md))
        report_dir = os.path.dirname(report_path)
        if report_dir:
            os.makedirs(report_dir, exist_ok=True)
        with open(report_path, "w", encoding="utf-8") as handle:
            handle.write(render_corpus_markdown(summary, artifacts))
        artifacts["report_md"] = report_path
    payload = {**artifacts, "summary": summary}
    if args.json:
        print(json.dumps(payload, indent=2, sort_keys=True))
    else:
        print(f"legion-bench corpus: {corpus.get('corpus')} ({len(mode_ids)} modes)")
        for mode_id, mode_summary in _dict(summary.get("modes")).items():
            metrics = _dict(_dict(mode_summary).get("metrics"))
            print(
                f"  {mode_id}: {int(metrics.get('pass') or 0)}/{int(metrics.get('case_runs') or 0)} "
                f"pass_rate={float(metrics.get('pass_rate') or 0):.3f} "
                f"cost=${float(metrics.get('cost_usd') or 0):.6f} "
                f"tokens={int(metrics.get('tokens') or 0)}"
            )
        for key, comparison in _dict(summary.get("comparisons")).items():
            reliable = "reliable" if comparison.get("reliable") else "small-sample"
            paired = _dict(comparison.get("paired"))
            print(
                f"  {key}: {float(comparison.get('delta_pct_points') or 0):+g} pp "
                f"({reliable}, paired wins "
                f"{int(paired.get('candidate_only_pass') or 0)}-"
                f"{int(paired.get('baseline_only_pass') or 0)})"
            )
        print(f"run: {artifacts['run_path']}")
        if report_path:
            print(f"report: {report_path}")
        if recorded_outcomes:
            print(f"recorded outcomes: {len(recorded_outcomes)}")
    if args.require_reliable:
        unreliable = [
            key
            for key, comparison in _dict(summary.get("comparisons")).items()
            if not _dict(comparison).get("reliable")
        ]
        if unreliable:
            print(f"legion-bench corpus: unreliable sample size for {', '.join(unreliable)}", file=sys.stderr)
            return 1
    if args.strict and not summary.get("ok"):
        return 1
    return 0


def run_command(args: argparse.Namespace) -> int:
    repo = os.path.abspath(args.repo)
    suite = load_suite(repo, args.suite)
    suite_name = _text(suite.get("suite")) or "suite"
    run_id = args.run_id or _run_id(suite_name)
    run_payload = _run_suite_artifacts(repo=repo, suite=suite, bench_dir=args.bench_dir, run_id=run_id)
    results = _list(run_payload.get("results"))
    summary = _dict(run_payload.get("summary"))
    artifacts = _dict(run_payload.get("artifacts"))
    telemetry_dir = args.telemetry_dir or os.environ.get("LEGION_TELEMETRY_DIR") or os.path.join(
        os.path.expanduser(args.logs), "spans"
    )
    span_path = emit_bench_span(summary, artifacts, telemetry_dir)
    recorded = []
    if args.record_failures:
        recorded = record_failed_outcomes(
            results,
            log_root=args.logs,
            run_path=artifacts["run_path"],
            run_id=run_id,
            suite_name=suite_name,
        )
    payload = {
        **artifacts,
        "span_path": span_path,
        "recorded_outcomes": len(recorded),
        "summary": summary,
    }
    if args.json:
        print(json.dumps(payload, indent=2, sort_keys=True))
    elif not args.quiet:
        metrics = _dict(summary.get("metrics"))
        print(
            "legion-bench: "
            f"{suite_name} {metrics.get('cases')} cases, "
            f"{metrics.get('pass')} pass, {metrics.get('fail')} fail "
            f"(required {metrics.get('required_pass')}/{metrics.get('required_cases')})"
        )
        print(f"run: {artifacts['run_path']}")
        print(f"summary: {artifacts['summary_path']}")
        if recorded:
            print(f"recorded outcomes: {len(recorded)}")
    if args.strict and not summary.get("ok"):
        return 1
    return 0


def stable_command(args: argparse.Namespace) -> int:
    repo = os.path.abspath(args.repo)
    suite = load_suite(repo, args.suite)
    suite_name = _text(suite.get("suite")) or "suite"
    run_id = args.run_id or _run_id(f"{suite_name}-stable")
    iterations = []
    repeat = max(1, int(args.repeat or 1))
    for index in range(repeat):
        iteration_id = f"{run_id}-iter-{index + 1:02d}"
        iterations.append(
            _run_suite_artifacts(
                repo=repo,
                suite=suite,
                bench_dir=args.bench_dir,
                run_id=iteration_id,
            )
        )
    payload = stability_rollup(suite, iterations, run_id=run_id, repo=repo)
    artifacts = write_stability_artifact(args.bench_dir, run_id, payload)
    payload["artifacts"] = artifacts
    if args.json:
        print(json.dumps(payload, indent=2, sort_keys=True))
    else:
        metrics = _dict(payload.get("metrics"))
        print(
            "legion-bench stable: "
            f"{suite_name} {metrics.get('iterations')}x"
            f"{metrics.get('cases_per_iteration')} cases, "
            f"min_score={float(metrics.get('min_score') or 0):.3f}, "
            f"flakes={metrics.get('flake_count')}"
        )
        print(f"stability: {artifacts['stability_path']}")
    if args.strict and not payload.get("ok"):
        return 1
    return 0


def compare_command(args: argparse.Namespace) -> int:
    baseline = load_run_or_summary(args.baseline)
    candidate = load_run_or_summary(args.candidate)
    payload = compare_summaries(baseline, candidate)
    if args.json:
        print(json.dumps(payload, indent=2, sort_keys=True))
    else:
        print(f"legion-bench compare: {payload['status']}")
        headline = _dict(payload.get("headline"))
        relative = headline.get("relative_improvement_pct")
        relative_text = "n/a" if relative is None else f"{float(relative):+g}%"
        print(
            "  score: "
            f"{float(headline.get('baseline') or 0):.3f} -> "
            f"{float(headline.get('candidate') or 0):.3f} "
            f"({float(headline.get('delta_pct_points') or 0):+g} pp, "
            f"{relative_text} relative)"
        )
        for key in payload["quality_regressions"]:
            delta = payload["metrics"][key]["delta"]
            print(f"  regression {key}: {delta:+g}")
        for key in payload["quality_improvements"]:
            delta = payload["metrics"][key]["delta"]
            print(f"  improvement {key}: {delta:+g}")
    return 0


def gate_command(args: argparse.Namespace) -> int:
    baseline = load_run_or_summary(args.baseline)
    candidate = load_run_or_summary(args.candidate)
    gate = _dict(candidate.get("gate")) or _dict(baseline.get("gate"))
    payload = gate_decision(compare_summaries(baseline, candidate), gate)
    if args.json:
        print(json.dumps(payload, indent=2, sort_keys=True))
    else:
        print(f"legion-bench gate: {payload['status']}")
        for failure in payload["failures"]:
            print(f"  {failure}")
    return 0 if payload["status"] == "pass" else 1


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(prog="legion-bench")
    sub = parser.add_subparsers(dest="cmd")

    run = sub.add_parser("run", help="run a deterministic Legion benchmark suite")
    run.add_argument("--repo", default=default_repo())
    run.add_argument("--suite", default="core")
    run.add_argument("--bench-dir", default=os.environ.get("LEGION_BENCH_DIR", DEFAULT_BENCH_ROOT))
    run.add_argument("--logs", default=DEFAULT_LOG_ROOT)
    run.add_argument("--telemetry-dir", default="")
    run.add_argument("--run-id", default="")
    run.add_argument("--record-failures", action="store_true")
    run.add_argument("--strict", action="store_true")
    run.add_argument("--json", action="store_true")
    run.add_argument("--quiet", action="store_true")

    stable = sub.add_parser("stable", help="run a suite repeatedly and report stability/flake metrics")
    stable.add_argument("--repo", default=default_repo())
    stable.add_argument("--suite", default="stable")
    stable.add_argument("--repeat", type=int, default=3)
    stable.add_argument("--bench-dir", default=os.environ.get("LEGION_BENCH_DIR", DEFAULT_BENCH_ROOT))
    stable.add_argument("--run-id", default="")
    stable.add_argument("--strict", action="store_true")
    stable.add_argument("--json", action="store_true")

    corpus = sub.add_parser("corpus", help="run an A/B task corpus across harness modes")
    corpus.add_argument("--repo", default=default_repo())
    corpus.add_argument("--corpus", default="local-smoke")
    corpus.add_argument("--mode", action="append", default=[], help="mode id to run; repeat to select multiple")
    corpus.add_argument("--baseline", default="", help="baseline mode id for lift comparisons")
    corpus.add_argument("--repeat", type=int, default=1)
    corpus.add_argument("--reliability-min-cases", type=int, default=0)
    corpus.add_argument("--bench-dir", default=os.environ.get("LEGION_BENCH_DIR", DEFAULT_BENCH_ROOT))
    corpus.add_argument("--logs", default=DEFAULT_LOG_ROOT)
    corpus.add_argument("--record-failures", action="store_true", help="record failed required case-runs as legion-self-learn outcomes, attributed to the failing mode")
    corpus.add_argument("--run-id", default="")
    corpus.add_argument("--dry-run", action="store_true", help="validate corpus shape and selected modes without executing cases")
    corpus.add_argument("--report-md", default="", help="write a Markdown corpus report to this path")
    corpus.add_argument("--strict", action="store_true")
    corpus.add_argument("--require-reliable", action="store_true")
    corpus.add_argument("--json", action="store_true")

    comp = sub.add_parser("compare", help="compare two benchmark run artifacts")
    comp.add_argument("--baseline", required=True)
    comp.add_argument("--candidate", required=True)
    comp.add_argument("--json", action="store_true")

    gate = sub.add_parser("gate", help="fail when a candidate benchmark regresses")
    gate.add_argument("--baseline", required=True)
    gate.add_argument("--candidate", required=True)
    gate.add_argument("--json", action="store_true")

    lift = sub.add_parser("learning-lift", help="run a synthetic before/after self-learning lift fixture")
    lift.add_argument("--repo", default=default_repo())
    lift.add_argument("--bench-dir", default=os.environ.get("LEGION_BENCH_DIR", DEFAULT_BENCH_ROOT))
    lift.add_argument("--logs", default="", help="log root; default is an isolated run workspace")
    lift.add_argument("--telemetry-dir", default="")
    lift.add_argument("--run-id", default="")
    lift.add_argument(
        "--correction",
        default="u should have linked the right harness bench repo, wrong attribution source",
    )
    lift.add_argument("--strict", action="store_true")
    lift.add_argument("--json", action="store_true")

    args = parser.parse_args(argv)
    try:
        if args.cmd == "run":
            return run_command(args)
        if args.cmd == "stable":
            return stable_command(args)
        if args.cmd == "corpus":
            return corpus_command(args)
        if args.cmd == "compare":
            return compare_command(args)
        if args.cmd == "gate":
            return gate_command(args)
        if args.cmd == "learning-lift":
            return learning_lift_command(args)
    except (FileNotFoundError, ValueError, RuntimeError) as exc:
        print(f"legion-bench: {exc}", file=sys.stderr)
        return 2
    parser.print_help()
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
