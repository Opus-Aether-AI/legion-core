#!/usr/bin/env python3
"""legion-health — which coding executors can take work right now.

  legion-health status [EXECUTOR...] [--json]     # recorded health (no probing)
  legion-health probe  [EXECUTOR...] [--json]     # offline static probe, recorded
  legion-health check  EXECUTOR [--no-probe]      # exit 0 available, 1 unavailable
  legion-health pick   --exclude NAME [--json]    # first healthy fallback executor
  legion-health record EXECUTOR --status ok|unavailable [--reason R] [--detail D]
  legion-health observe EXECUTOR --run-status S [--reason-hint R] [--file F ...]
  legion-health reset  [EXECUTOR...]

legion-delegate consults `check` before dispatch and `pick` for a fallback;
adapters call `observe` when a run ends. See legion_executor_health.py for the
evidence rules. LEGION_HEALTH=off disables health routing entirely.
"""

from __future__ import annotations

import argparse
import json
import os
import sys

sys.path.insert(
    0,
    os.path.abspath(
        os.path.join(os.path.dirname(__file__), "..", "..", "legion-observability", "scripts")
    ),
)

import legion_executor_health as health  # noqa: E402

MAX_OBSERVED_BYTES = 256 * 1024


def _read_tail(path: str) -> str:
    try:
        with open(path, "rb") as fh:
            fh.seek(0, os.SEEK_END)
            size = fh.tell()
            fh.seek(max(0, size - MAX_OBSERVED_BYTES))
            return fh.read().decode("utf-8", "replace")
    except OSError:
        return ""


def _print_rows(rows, as_json):
    if as_json:
        print(json.dumps(rows, indent=2, sort_keys=True))
        return
    for row in rows:
        state = "available" if row.get("available") else "UNAVAILABLE"
        if row.get("source") == "none":
            state = "available (no record yet)"
        elif row.get("available") and not row.get("fresh"):
            state = "available (record stale)"
        reason = f" ({row['reason']})" if row.get("reason") else ""
        detail = f" -- {row['detail']}" if row.get("detail") else ""
        print(f"{row['executor']:<10} {state}{reason}{detail}")


def main(argv=None) -> int:
    parser = argparse.ArgumentParser(prog="legion-health", description="Executor health for routing.")
    sub = parser.add_subparsers(dest="cmd", required=True)

    p_status = sub.add_parser("status", help="show recorded health without probing")
    p_status.add_argument("executors", nargs="*")
    p_status.add_argument("--json", action="store_true")

    p_probe = sub.add_parser("probe", help="run the offline static probe and record it")
    p_probe.add_argument("executors", nargs="*")
    p_probe.add_argument("--json", action="store_true")

    p_check = sub.add_parser("check", help="exit 0 when available, 1 when unavailable")
    p_check.add_argument("executor")
    p_check.add_argument("--no-probe", action="store_true", help="never re-probe a stale outage")
    p_check.add_argument("--json", action="store_true", help="accepted; output is always JSON")

    p_pick = sub.add_parser("pick", help="first healthy executor in the fallback order")
    p_pick.add_argument("--exclude", action="append", default=[])
    p_pick.add_argument("--order", default="", help="comma-separated order (default: routing.toml [health])")
    p_pick.add_argument("--json", action="store_true")

    p_record = sub.add_parser("record", help="store one executor's health")
    p_record.add_argument("executor")
    p_record.add_argument("--status", required=True, choices=["ok", "unavailable"])
    p_record.add_argument("--reason", default="", choices=["", *health.REASONS])
    p_record.add_argument("--detail", default="")
    p_record.add_argument("--source", default="manual")
    p_record.add_argument("--ttl", type=int, default=None, help="seconds before a recheck")

    p_observe = sub.add_parser("observe", help="fold a finished run into the record")
    p_observe.add_argument("executor")
    p_observe.add_argument("--run-status", required=True)
    p_observe.add_argument("--reason-hint", default="")
    p_observe.add_argument("--default-reason", default="", help="reason to record when the text names none")
    p_observe.add_argument("--file", action="append", default=[], help="stderr or error file to classify")
    p_observe.add_argument("--text", action="append", default=[], help="adapter-reported error text")

    p_reset = sub.add_parser("reset", help="forget recorded health")
    p_reset.add_argument("executors", nargs="*")

    args = parser.parse_args(argv)
    try:
        if args.cmd in ("status", "probe"):
            names = args.executors or health.coding_executors()
            rows = [
                health.evaluate(name, probe_stale=False, force_probe=args.cmd == "probe")
                for name in names
            ]
            _print_rows(rows, args.json)
            return 0
        if args.cmd == "check":
            verdict = health.evaluate(args.executor, probe_stale=not args.no_probe)
            print(json.dumps(verdict, sort_keys=True))
            return 0 if verdict["available"] else 1
        if args.cmd == "pick":
            order = [part.strip() for part in args.order.split(",") if part.strip()] or None
            choice = health.pick(args.exclude, order=order)
            if args.json:
                print(json.dumps(choice, sort_keys=True))
            elif choice["executor"]:
                print(choice["executor"])
            return 0 if choice["executor"] else 1
        if args.cmd == "record":
            entry = health.record(
                args.executor, args.status, args.reason, args.detail, args.source, ttl=args.ttl
            )
            print(json.dumps({"executor": args.executor, **entry}, sort_keys=True))
            return 0
        if args.cmd == "observe":
            texts = list(args.text) + [_read_tail(path) for path in args.file]
            entry = health.observe(
                args.executor,
                args.run_status,
                reason_hint=args.reason_hint,
                texts=texts,
                default_reason=args.default_reason,
            )
            if entry is not None:
                print(json.dumps({"executor": args.executor.split("-", 1)[0], **entry}, sort_keys=True))
            return 0
        if args.cmd == "reset":
            health.reset(args.executors or None)
            return 0
    except (health.HealthError, OSError) as exc:
        print(f"legion-health: {exc}", file=sys.stderr)
        return 2
    return 2


if __name__ == "__main__":
    sys.exit(main())
