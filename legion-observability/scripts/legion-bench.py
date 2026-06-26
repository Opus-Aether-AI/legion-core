#!/usr/bin/env python3
"""legion-bench - deterministic benchmark workbench for Legion harness changes."""

from __future__ import annotations

import argparse
import hashlib
import importlib.util
import json
import os
import shlex
import subprocess
import sys
import time
from datetime import datetime, timezone
from typing import Any


SUITE_SCHEMA = "legion.bench.suite.v1"
CASE_RESULT_SCHEMA = "legion.bench.case-result.v1"
RUN_SCHEMA = "legion.bench.run.v1"
SUMMARY_SCHEMA = "legion.bench.summary.v1"
LATEST_SCHEMA = "legion.bench.latest.v1"
COMPARE_SCHEMA = "legion.bench.compare.v1"
OUTCOME_SCHEMA = "legion.outcome.v1"
SPAN_SCHEMA = "legion.span.v1"
DEFAULT_LOG_ROOT = "~/.claude/logs/legion"
DEFAULT_BENCH_ROOT = "~/.claude/logs/legion/bench"
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


def load_suite(repo: str, suite: str) -> dict[str, Any]:
    path = resolve_suite_path(repo, suite)
    payload = _json_file(path)
    if payload.get("schema") != SUITE_SCHEMA:
        raise ValueError(f"{path} is not a {SUITE_SCHEMA} suite")
    cases = payload.get("cases")
    if not isinstance(cases, list) or not cases:
        raise ValueError(f"{path} has no benchmark cases")
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
        else:
            results.append(_validator_result(kind or "unknown", False, "unknown validator"))
    return results


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

    command = _render(case.get("command"), context)
    if isinstance(command, str):
        argv = shlex.split(command)
    elif isinstance(command, list) and all(isinstance(item, str) for item in command):
        argv = command
    else:
        raise ValueError("task case requires command as a string or string list")

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
        "reason": _short(_text(payload.get("reason")), 500),
        "false_success": bool(payload.get("false_success")),
        "metrics": _dict(payload.get("metrics")),
        "details": _dict(payload.get("details")),
    }


def _rate(numer: int, denom: int) -> float:
    return round(numer / denom, 6) if denom else 0.0


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
        "span_path": span_path,
    }


def learning_lift_command(args: argparse.Namespace) -> int:
    payload = learning_lift_payload(args)
    comparison = _dict(payload.get("comparison"))
    headline = _dict(comparison.get("headline"))
    if args.json:
        print(json.dumps(payload, indent=2, sort_keys=True))
    else:
        relative = headline.get("relative_improvement_pct")
        relative_text = "n/a" if relative is None else f"{float(relative):+g}%"
        print(
            "legion-bench learning-lift: "
            f"{float(headline.get('baseline') or 0):.3f} -> "
            f"{float(headline.get('candidate') or 0):.3f} "
            f"({float(headline.get('delta_pct_points') or 0):+g} pp, "
            f"{relative_text} relative)"
        )
        print(f"baseline: {payload['baseline']['artifacts']['run_path']}")
        print(f"candidate: {payload['candidate']['artifacts']['run_path']}")
    if args.strict:
        candidate_ok = bool(_dict(payload.get("candidate")).get("summary", {}).get("ok"))
        improved = comparison.get("status") == "improved"
        if not candidate_ok or not improved:
            return 1
    return 0


def run_command(args: argparse.Namespace) -> int:
    repo = os.path.abspath(args.repo)
    suite = load_suite(repo, args.suite)
    suite_name = _text(suite.get("suite")) or "suite"
    run_id = args.run_id or _run_id(suite_name)
    run_dir = os.path.join(os.path.abspath(os.path.expanduser(args.bench_dir)), "runs", run_id)
    start = time.monotonic()
    results = [run_case(case, repo, run_dir) for case in _list(suite.get("cases"))]
    duration_ms = int((time.monotonic() - start) * 1000)
    summary = summarize_run(suite, results, run_id=run_id, repo=repo, duration_ms=duration_ms)
    artifacts = write_run_artifacts(args.bench_dir, run_id, suite, results, summary)
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
