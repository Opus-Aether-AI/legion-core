#!/usr/bin/env python3
"""Build a read-only Legion Console snapshot from registry + spans."""

from __future__ import annotations

import argparse
import json
import os
import sys
import time
from datetime import datetime, timezone
from typing import Any


RUN_SCHEMA = "legion.run-state.v1"
SPAN_SCHEMA = "legion.span.v1"
TOKEN_FIELDS = (
    "input_tokens",
    "cached_input_tokens",
    "output_tokens",
    "reasoning_output_tokens",
)
DEFAULT_ROOT = os.path.expanduser("~/.claude/logs/legion")


def _num(value: Any) -> float:
    if isinstance(value, bool):
        return 0.0
    if isinstance(value, (int, float)) and value == value:
        return float(value)
    return 0.0


def _dict(value: Any) -> dict[str, Any]:
    return value if isinstance(value, dict) else {}


def _parse_epoch(value: Any) -> float | None:
    if isinstance(value, bool):
        return None
    if isinstance(value, (int, float)) and value == value:
        return float(value)
    if not isinstance(value, str):
        return None
    text = value.strip()
    if not text:
        return None
    if text.endswith("Z"):
        text = text[:-1] + "+00:00"
    try:
        dt = datetime.fromisoformat(text)
    except ValueError:
        return None
    if dt.tzinfo is None:
        dt = dt.replace(tzinfo=timezone.utc)
    return dt.timestamp()


def _ts_key(value: Any) -> tuple[int, float | str]:
    parsed = _parse_epoch(value)
    if parsed is not None:
        return (1, parsed)
    if isinstance(value, str):
        return (0, value)
    return (0, "")


def _iso_utc(epoch: float) -> str:
    return datetime.fromtimestamp(epoch, tz=timezone.utc).isoformat().replace(
        "+00:00", "Z"
    )


def _resolve_now(now: Any = None) -> tuple[str, float]:
    if now is None:
        epoch = time.time()
        return _iso_utc(epoch), epoch
    if isinstance(now, str):
        parsed = _parse_epoch(now)
        if parsed is None:
            raise ValueError("now must be parseable as an ISO-8601 timestamp")
        return now, parsed
    if isinstance(now, datetime):
        dt = now
        if dt.tzinfo is None:
            dt = dt.replace(tzinfo=timezone.utc)
        return dt.isoformat().replace("+00:00", "Z"), dt.timestamp()
    epoch = _parse_epoch(now)
    if epoch is None:
        raise ValueError("now must be None, datetime, number, or ISO-8601 string")
    return _iso_utc(epoch), epoch


def _sum_tokens(total: dict[str, int], tokens: Any) -> None:
    data = _dict(tokens)
    for field in TOKEN_FIELDS:
        total[field] += int(_num(data.get(field)))


def _tokens_total(tokens: Any) -> int:
    data = _dict(tokens)
    return sum(int(_num(data.get(field))) for field in TOKEN_FIELDS)


def _started_at(record: dict[str, Any]) -> Any:
    lifecycle = _dict(record.get("lifecycle"))
    process = _dict(record.get("process"))
    return lifecycle.get("started_at") or process.get("started_at")


def _updated_at(record: dict[str, Any]) -> Any:
    lifecycle = _dict(record.get("lifecycle"))
    return lifecycle.get("updated_at") or _started_at(record)


def load_registry(directory: str) -> list[dict[str, Any]]:
    """Load valid run-state records from a registry directory."""
    records: list[dict[str, Any]] = []
    if not os.path.isdir(directory):
        return records
    try:
        entries = sorted(os.scandir(directory), key=lambda entry: entry.name)
    except OSError:
        return records
    for entry in entries:
        if not entry.is_file():
            continue
        try:
            with open(entry.path, encoding="utf-8") as handle:
                record = json.load(handle)
        except (OSError, ValueError, TypeError):
            continue
        if (
            isinstance(record, dict)
            and record.get("schema") == RUN_SCHEMA
            and record.get("run_id")
        ):
            records.append(record)
    return records


def load_spans(directory: str) -> dict[str, dict[str, Any]]:
    """Load latest span per run_id, summing cost and tokens across all spans."""
    latest_by_run: dict[str, dict[str, Any]] = {}
    totals_by_run: dict[str, dict[str, Any]] = {}
    if not os.path.isdir(directory):
        return latest_by_run
    try:
        entries = sorted(os.scandir(directory), key=lambda entry: entry.name)
    except OSError:
        return latest_by_run
    for entry in entries:
        if not entry.is_file():
            continue
        try:
            with open(entry.path, encoding="utf-8") as handle:
                for raw_line in handle:
                    line = raw_line.strip()
                    if not line:
                        continue
                    try:
                        span = json.loads(line)
                    except (ValueError, TypeError):
                        continue
                    if not isinstance(span, dict) or span.get("schema") != SPAN_SCHEMA:
                        continue
                    run_id = span.get("run_id")
                    if not run_id:
                        continue

                    totals = totals_by_run.setdefault(
                        run_id,
                        {
                            "cost_usd": 0.0,
                            "tokens": {field: 0 for field in TOKEN_FIELDS},
                        },
                    )
                    totals["cost_usd"] += _num(span.get("cost_usd"))
                    _sum_tokens(totals["tokens"], span.get("tokens"))

                    current = latest_by_run.get(run_id)
                    if current is None or _ts_key(span.get("ts")) >= _ts_key(
                        current.get("ts")
                    ):
                        latest_by_run[run_id] = dict(span)
        except OSError:
            continue

    for run_id, span in latest_by_run.items():
        totals = totals_by_run[run_id]
        span["cost_usd"] = round(totals["cost_usd"], 6)
        span["tokens"] = totals["tokens"]
    return latest_by_run


def pid_alive(pid: Any) -> bool:
    """Return whether a PID appears to be alive."""
    if isinstance(pid, bool):
        return False
    try:
        value = int(pid)
    except (TypeError, ValueError):
        return False
    if value <= 0:
        return False
    try:
        os.kill(value, 0)
    except ProcessLookupError:
        return False
    except PermissionError:
        return True
    except OSError:
        return False
    return True


def _terminal_status(status: Any, diff_exists: bool, worktree_exists: bool) -> str | None:
    if status in ("failed", "error"):
        return "failed"
    if status in ("ok", "over_budget"):
        # awaiting_human only when there's an actionable diff AND its worktree still
        # exists (resumable/applicable). A terminal run whose ephemeral worktree was
        # cleaned is concluded -> done; a leftover diff.patch alone isn't a pending
        # action (and may already have been applied outside legion).
        return "awaiting_human" if (diff_exists and worktree_exists) else "done"
    return None


def derive_status(
    record: dict[str, Any],
    span: dict[str, Any] | None,
    *,
    alive: bool,
    worktree_exists: bool,
    diff_exists: bool,
) -> str:
    """Derive the Legion Console status for a run."""
    phase = _dict(record.get("lifecycle")).get("phase")

    # A preallocated, not-yet-launched slice (e.g. a legion-fanout queue entry): no
    # span, no live process. Once the delegate adopts the id it rewrites phase=running.
    if phase == "queued" and span is None and not alive:
        return "queued"

    if phase == "running":
        if alive:
            return "running"
        if span is None:
            return "orphaned"
        derived = _terminal_status(span.get("status"), diff_exists, worktree_exists)
        return derived or "orphaned"

    status = span.get("status") if span is not None else phase
    derived = _terminal_status(status, diff_exists, worktree_exists)
    if derived is not None:
        return derived
    fallback = _terminal_status(phase, diff_exists, worktree_exists)
    return fallback or "unknown"


def _build_run(record: dict[str, Any], span: dict[str, Any] | None, now: Any = None) -> dict[str, Any]:
    generated_at, now_epoch = _resolve_now(now)
    del generated_at

    process = _dict(record.get("process"))
    pid = process.get("pid")
    pgid = process.get("pgid")
    run_dir = record.get("run_dir") if isinstance(record.get("run_dir"), str) else ""
    worktree_dir = (
        record.get("worktree_dir") if isinstance(record.get("worktree_dir"), str) else ""
    )
    worktree_exists = os.path.isdir(worktree_dir)
    diff_exists = bool(run_dir) and os.path.isfile(os.path.join(run_dir, "diff.patch"))
    alive = pid_alive(pid)
    status = derive_status(
        record, span, alive=alive, worktree_exists=worktree_exists, diff_exists=diff_exists
    )
    started_at = _started_at(record)
    updated_at = _updated_at(record)
    started_epoch = _parse_epoch(started_at)
    # Live runs tick to now; finished runs freeze at their terminal write (updated_at),
    # so a done agent doesn't keep counting elapsed forever.
    if status in ("running", "queued"):
        end_epoch = now_epoch
    else:
        end_epoch = _parse_epoch(updated_at)
        if end_epoch is None:
            end_epoch = now_epoch
    elapsed = 0
    if started_epoch is not None:
        delta = max(0.0, end_epoch - started_epoch)
        elapsed = int(delta) if delta.is_integer() else round(delta, 3)

    return {
        "run_id": record.get("run_id"),
        "status": status,
        "model": record.get("model"),
        "repo_root": record.get("repo_root"),
        "kind": record.get("kind"),
        "trace_id": record.get("trace_id"),
        "parent_id": record.get("parent_id"),
        "started_at": started_at,
        "updated_at": updated_at,
        "elapsed_s": elapsed,
        "cost_usd": round(_num((span or {}).get("cost_usd")), 6),
        "tokens_total": _tokens_total((span or {}).get("tokens")),
        "worktree_exists": worktree_exists,
        "diff_exists": diff_exists,
        "pid": pid,
        "pgid": pgid,
    }


def build_run(record: dict[str, Any], span: dict[str, Any] | None) -> dict[str, Any]:
    """Build a single console run view."""
    return _build_run(record, span)


def _run_sort_key(run: dict[str, Any]) -> tuple[float, str]:
    parsed = _parse_epoch(run.get("started_at"))
    return (parsed if parsed is not None else float("-inf"), str(run.get("run_id") or ""))


def _build_trace_group(runs: list[dict[str, Any]]) -> dict[str, Any]:
    ordered = sorted(runs, key=_run_sort_key, reverse=True)
    nodes: dict[str, dict[str, Any]] = {}
    for run in ordered:
        nodes[run["run_id"]] = {
            "run_id": run["run_id"],
            "parent_id": run.get("parent_id"),
            "status": run.get("status"),
            "children": [],
        }

    roots: list[dict[str, Any]] = []
    for run in ordered:
        node = nodes[run["run_id"]]
        parent_id = run.get("parent_id")
        if parent_id and parent_id in nodes:
            nodes[parent_id]["children"].append(node)
        else:
            roots.append(node)

    return {
        "trace_id": ordered[0].get("trace_id"),
        "runs": [run["run_id"] for run in ordered],
        "roots": roots,
        "cost_usd": round(sum(_num(run.get("cost_usd")) for run in ordered), 6),
    }


def build_snapshot(
    registry_dir: str,
    spans_dir: str,
    *,
    now: Any = None,
) -> dict[str, Any]:
    """Build a full Legion Console snapshot."""
    generated_at, _ = _resolve_now(now)
    records = load_registry(registry_dir)
    spans = load_spans(spans_dir)
    runs = [_build_run(record, spans.get(record.get("run_id")), now=now) for record in records]
    runs.sort(key=_run_sort_key, reverse=True)

    by_status: dict[str, int] = {}
    by_model: dict[str, dict[str, Any]] = {}
    total_cost = 0.0
    trace_groups: dict[str, list[dict[str, Any]]] = {}

    for run in runs:
        status = run.get("status") or "unknown"
        model = run.get("model") or "unknown"
        cost = _num(run.get("cost_usd"))
        by_status[status] = by_status.get(status, 0) + 1
        bucket = by_model.setdefault(model, {"runs": 0, "cost_usd": 0.0})
        bucket["runs"] += 1
        bucket["cost_usd"] = round(bucket["cost_usd"] + cost, 6)
        total_cost += cost
        trace_id = run.get("trace_id")
        if trace_id:
            trace_groups.setdefault(str(trace_id), []).append(run)

    traces = [
        _build_trace_group(group_runs)
        for _, group_runs in sorted(
            trace_groups.items(),
            key=lambda item: _run_sort_key(max(item[1], key=_run_sort_key)),
            reverse=True,
        )
    ]

    return {
        "generated_at": generated_at,
        "runs": runs,
        "aggregates": {
            "by_status": by_status,
            "by_model": by_model,
            "total_cost_usd": round(total_cost, 6),
            "running": by_status.get("running", 0),
            "awaiting_human": by_status.get("awaiting_human", 0),
        },
        "traces": traces,
    }


def _format_cost(value: Any) -> str:
    return f"{_num(value):.4f}"


def _format_elapsed(value: Any) -> str:
    seconds = _num(value)
    return str(int(seconds)) if seconds.is_integer() else f"{seconds:.1f}"


def _short(text: Any, width: int) -> str:
    value = str(text or "-")
    if len(value) <= width:
        return value
    if width <= 3:
        return value[:width]
    return value[: width - 3] + "..."


def _render_table(snapshot: dict[str, Any]) -> str:
    runs = snapshot.get("runs", [])
    if not runs:
        return f"generated_at={snapshot.get('generated_at')}\nNo runs found."

    rows = []
    for run in runs:
        rows.append(
            [
                _short(run.get("run_id"), 12),
                str(run.get("status") or "-"),
                _short(run.get("model"), 18),
                _short(run.get("kind"), 12),
                _format_elapsed(run.get("elapsed_s")),
                _format_cost(run.get("cost_usd")),
            ]
        )

    headers = ["run_id", "status", "model", "kind", "elapsed_s", "cost_usd"]
    widths = [
        max(len(headers[idx]), max(len(row[idx]) for row in rows))
        for idx in range(len(headers))
    ]
    lines = [f"generated_at={snapshot.get('generated_at')}"]
    lines.append(
        " ".join(headers[idx].ljust(widths[idx]) for idx in range(len(headers)))
    )
    lines.append(
        " ".join("-" * widths[idx] for idx in range(len(headers)))
    )
    for row in rows:
        lines.append(" ".join(row[idx].ljust(widths[idx]) for idx in range(len(row))))
    return "\n".join(lines)


def _default_registry_dir() -> str:
    return os.path.join(DEFAULT_ROOT, "registry")


def _default_spans_dir() -> str:
    return os.path.join(DEFAULT_ROOT, "spans")


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="Index Legion Console runtime state.")
    parser.add_argument("--registry", default=_default_registry_dir())
    parser.add_argument("--spans", default=_default_spans_dir())
    parser.add_argument("--json", action="store_true", help="Print the full snapshot as JSON.")
    parser.add_argument(
        "--watch",
        type=float,
        help="Rebuild and reprint the snapshot every N seconds.",
    )
    args = parser.parse_args(argv)

    if args.watch is not None and args.watch <= 0:
        parser.error("--watch must be > 0")

    try:
        while True:
            snapshot = build_snapshot(args.registry, args.spans)
            if args.json:
                print(json.dumps(snapshot, indent=2, sort_keys=True))
            else:
                print(_render_table(snapshot))
            if args.watch is None:
                break
            print()
            time.sleep(args.watch)
    except KeyboardInterrupt:
        return 130
    return 0


if __name__ == "__main__":
    sys.exit(main())
