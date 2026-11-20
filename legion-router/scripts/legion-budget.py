#!/usr/bin/env python3
"""legion-budget — default spending caps for delegated work.

  legion-budget caps   [--json] [--field run_usd|day_usd|review_fix_max_rounds]
  legion-budget status [--json] [--day YYYY-MM-DD]
  legion-budget check  [--json]                  # exit 0 under the day cap, 3 when spent
  legion-budget run-status --status S --cost USD # ok -> over_budget above the run cap

Caps resolve from the environment, then routing.toml [budget], then built-in
defaults. A cap of 0 turns that cap off.

  LEGION_RUN_BUDGET_USD          per delegated run
  LEGION_DAY_BUDGET_USD          per UTC day, summed over every project's spans
  LEGION_REVIEW_FIX_MAX_ROUNDS   review-and-fix rounds legion-converge allows

The day total counts delegated executor spans only (codex, claude, opencode,
... and their -review/-resume variants). Orchestrator roll-ups and synthetic
primary baselines would count the same spend twice.
"""

from __future__ import annotations

import argparse
import glob
import importlib.util
import json
import os
import sys
from datetime import datetime, timezone

_HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.abspath(os.path.join(_HERE, "..", "..", "legion-observability", "scripts")))

from legion_executor_registry import executor_family, load_coding_executor_families  # noqa: E402

DEFAULT_CAPS = {"run_usd": 10.0, "day_usd": 50.0, "review_fix_max_rounds": 3}
ENV_KEYS = {
    "run_usd": "LEGION_RUN_BUDGET_USD",
    "day_usd": "LEGION_DAY_BUDGET_USD",
    "review_fix_max_rounds": "LEGION_REVIEW_FIX_MAX_ROUNDS",
}
EXIT_EXHAUSTED = 3


def _route():
    path = os.path.join(_HERE, "legion-route.py")
    spec = importlib.util.spec_from_file_location("legion_route_for_budget", path)
    module = importlib.util.module_from_spec(spec)
    assert spec.loader is not None
    spec.loader.exec_module(module)
    return module


def _number(value, integer=False):
    if isinstance(value, bool):
        return None
    try:
        parsed = int(value) if integer else float(value)
    except (TypeError, ValueError):
        return None
    if parsed != parsed or parsed < 0:  # NaN or negative
        return None
    return parsed


def caps(env=None, routing=None) -> dict:
    """Resolved caps with the source of each value."""
    env = os.environ if env is None else env
    section = {}
    try:
        route = _route()
        table = route.load_table(routing or env.get("LEGION_ROUTING_FILE") or route._DEFAULT_FILE)
        if isinstance(table, dict) and isinstance(table.get("budget"), dict):
            section = table["budget"]
    except (OSError, ValueError):
        section = {}
    out, sources = {}, {}
    for key, default in DEFAULT_CAPS.items():
        integer = key == "review_fix_max_rounds"
        value = _number(env.get(ENV_KEYS[key]), integer) if env.get(ENV_KEYS[key]) not in (None, "") else None
        source = "env"
        if value is None:
            value, source = _number(section.get(key), integer), "routing.toml"
        if value is None:
            value, source = default, "default"
        out[key], sources[key] = value, source
    out["sources"] = sources
    return out


def _legion_home(env) -> str:
    home = env.get("HOME") or os.path.expanduser("~")
    return os.path.abspath(os.path.expanduser(env.get("LEGION_HOME") or os.path.join(home, ".legion")))


def span_files(day: str, env=None, extra_dirs=()) -> list[str]:
    env = os.environ if env is None else env
    dirs = list(extra_dirs)
    if env.get("LEGION_TELEMETRY_DIR"):
        dirs.append(env["LEGION_TELEMETRY_DIR"])
    dirs.extend(glob.glob(os.path.join(_legion_home(env), "projects", "*", "spans")))
    seen, files = set(), []
    for directory in dirs:
        path = os.path.join(os.path.expanduser(directory), f"{day}.jsonl")
        try:
            real = os.path.realpath(path)
        except OSError:
            continue
        if real in seen or not os.path.isfile(real):
            continue
        seen.add(real)
        files.append(real)
    return files


def day_spend(day: str | None = None, env=None, extra_dirs=()) -> dict:
    env = os.environ if env is None else env
    day = day or datetime.now(timezone.utc).strftime("%Y-%m-%d")
    families = load_coding_executor_families()
    total, runs, by_executor = 0.0, 0, {}
    files = span_files(day, env, extra_dirs)
    for path in files:
        try:
            with open(path, encoding="utf-8") as fh:
                for line in fh:
                    try:
                        span = json.loads(line)
                    except ValueError:
                        continue
                    if not isinstance(span, dict) or span.get("schema") != "legion.span.v1":
                        continue
                    family = executor_family(span.get("executor"), families)
                    if family is None:
                        continue
                    artifacts = span.get("artifacts") if isinstance(span.get("artifacts"), dict) else {}
                    if artifacts.get("synthetic_primary_baseline") or artifacts.get("synthetic_opus_baseline"):
                        continue
                    cost = _number(span.get("cost_usd"))
                    if not cost:
                        continue
                    total += cost
                    runs += 1
                    by_executor[family] = round(by_executor.get(family, 0.0) + cost, 6)
        except OSError:
            continue
    return {"day": day, "spent_usd": round(total, 6), "metered_spans": runs,
            "by_executor": by_executor, "span_files": len(files)}


def check(env=None, extra_dirs=()) -> dict:
    resolved = caps(env)
    spend = day_spend(env=env, extra_dirs=extra_dirs)
    cap = resolved["day_usd"]
    exhausted = bool(cap) and spend["spent_usd"] >= cap
    return {
        "status": "exhausted" if exhausted else "ok",
        "day_usd_cap": cap,
        "run_usd_cap": resolved["run_usd"],
        **spend,
        "remaining_usd": None if not cap else round(max(0.0, cap - spend["spent_usd"]), 6),
    }


def run_status(status: str, cost, env=None) -> str:
    cap = caps(env)["run_usd"]
    spent = _number(cost) or 0.0
    if status == "ok" and cap and spent > cap:
        return "over_budget"
    return status


def main(argv=None) -> int:
    parser = argparse.ArgumentParser(prog="legion-budget", description="Default spending caps.")
    sub = parser.add_subparsers(dest="cmd", required=True)
    p_caps = sub.add_parser("caps", help="resolved caps")
    p_caps.add_argument("--json", action="store_true")
    p_caps.add_argument("--field", choices=sorted(DEFAULT_CAPS))
    p_status = sub.add_parser("status", help="today's delegated spend against the caps")
    p_status.add_argument("--json", action="store_true")
    p_status.add_argument("--day", default=None)
    p_status.add_argument("--dir", action="append", default=[], help="extra span directory")
    p_check = sub.add_parser("check", help="exit 3 when the day cap is spent")
    p_check.add_argument("--json", action="store_true")
    p_check.add_argument("--dir", action="append", default=[], help="extra span directory")
    p_run = sub.add_parser("run-status", help="apply the per-run cap to a finished run")
    p_run.add_argument("--status", required=True)
    p_run.add_argument("--cost", required=True)
    args = parser.parse_args(argv)

    if args.cmd == "caps":
        resolved = caps()
        if args.field:
            value = resolved[args.field]
            print(int(value) if args.field == "review_fix_max_rounds" else f"{value:g}")
        elif args.json:
            print(json.dumps(resolved, sort_keys=True))
        else:
            for key in DEFAULT_CAPS:
                print(f"{key} = {resolved[key]:g}  ({resolved['sources'][key]})")
        return 0
    if args.cmd == "status":
        payload = {**caps(), **day_spend(args.day, extra_dirs=args.dir)}
        if args.json:
            print(json.dumps(payload, sort_keys=True))
        else:
            cap = payload["day_usd"]
            limit = f"${cap:g}" if cap else "no cap"
            print(f"{payload['day']}: ${payload['spent_usd']:.4f} delegated spend of {limit}; "
                  f"per-run cap {'$%g' % payload['run_usd'] if payload['run_usd'] else 'off'}")
        return 0
    if args.cmd == "check":
        payload = check(extra_dirs=args.dir)
        print(json.dumps(payload, sort_keys=True))
        return EXIT_EXHAUSTED if payload["status"] == "exhausted" else 0
    if args.cmd == "run-status":
        print(run_status(args.status, args.cost))
        return 0
    return 2


if __name__ == "__main__":
    sys.exit(main())
