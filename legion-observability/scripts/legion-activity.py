#!/usr/bin/env python3
"""Build Legion Console activity views from registry records + codex streams."""

from __future__ import annotations

import argparse
import json
import os
import sys
from collections import Counter
from datetime import datetime, timezone
from typing import Any


RUN_SCHEMA = "legion.run-state.v1"
TOKEN_FIELDS = (
    "input_tokens",
    "cached_input_tokens",
    "output_tokens",
    "reasoning_output_tokens",
)
TOOLLESS_ITEM_TYPES = {"agent_message", "reasoning"}
FILE_ITEM_TYPES = {"file_change", "patch"}
PATH_KEYS = {
    "destination",
    "destination_path",
    "file",
    "file_path",
    "filepath",
    "new_path",
    "old_path",
    "path",
    "relative_path",
    "source",
    "source_path",
    "target",
    "target_path",
}
GENERIC_PATH_KEYS = {"source", "target"}
DEFAULT_ROOT = os.path.expanduser("~/.claude/logs/legion")
HERE = os.path.dirname(os.path.abspath(__file__))


def _num(value: Any) -> float:
    if isinstance(value, bool):
        return 0.0
    if isinstance(value, (int, float)) and value == value:
        return float(value)
    return 0.0


def _dict(value: Any) -> dict[str, Any]:
    return value if isinstance(value, dict) else {}


def _string(value: Any) -> str:
    return value.strip() if isinstance(value, str) else ""


def _iso_utc() -> str:
    return datetime.now(timezone.utc).isoformat().replace("+00:00", "Z")


def _zero_usage() -> dict[str, int]:
    return {field: 0 for field in TOKEN_FIELDS}


def _empty_activity() -> dict[str, Any]:
    return {
        "usage": _zero_usage(),
        "tools": [],
        "files": [],
        "items": 0,
        "summary": "0 items · 0 tools · 0 files",
    }


def _sum_usage(total: dict[str, int], usage: Any) -> None:
    data = _dict(usage)
    for field in TOKEN_FIELDS:
        total[field] += int(max(0.0, _num(data.get(field))))


def _normalize_costs(costs: Any) -> dict[str, Any]:
    default = _dict(_dict(costs).get("default"))
    return {
        "models": [
            model for model in _dict(costs).get("models", []) if isinstance(model, dict)
        ],
        "default": {
            "input": _num(default.get("input")),
            "output": _num(default.get("output")),
            "cache_read": _num(default.get("cache_read")),
            "cache_write": _num(default.get("cache_write")),
        },
    }


def _default_costs() -> dict[str, Any]:
    return {
        "models": [],
        "default": {
            "input": 0.0,
            "output": 0.0,
            "cache_read": 0.0,
            "cache_write": 0.0,
        },
    }


def load_costs(costs_path: str) -> dict[str, Any]:
    """Load the shared Legion per-model cost table."""
    if not costs_path:
        return _default_costs()
    try:
        with open(costs_path, encoding="utf-8") as handle:
            return _normalize_costs(json.load(handle))
    except (OSError, TypeError, ValueError):
        return _default_costs()


def _rates_for(model: Any, costs: dict[str, Any]) -> dict[str, float]:
    model_name = _string(model).lower()
    for entry in costs.get("models", []):
        match = _string(entry.get("match")).lower()
        if match and match in model_name:
            return {
                "input": _num(entry.get("input")),
                "output": _num(entry.get("output")),
                "cache_read": _num(entry.get("cache_read")),
                "cache_write": _num(entry.get("cache_write")),
            }
    default = _dict(costs.get("default"))
    return {
        "input": _num(default.get("input")),
        "output": _num(default.get("output")),
        "cache_read": _num(default.get("cache_read")),
        "cache_write": _num(default.get("cache_write")),
    }


def cost_for(model: Any, usage: Any, costs: dict[str, Any]) -> float:
    """Compute USD cost from token usage using the Legion shared price table."""
    data = _dict(usage)
    input_tokens = int(max(0.0, _num(data.get("input_tokens"))))
    cached_tokens = int(max(0.0, _num(data.get("cached_input_tokens"))))
    output_tokens = int(max(0.0, _num(data.get("output_tokens"))))
    reasoning_tokens = int(max(0.0, _num(data.get("reasoning_output_tokens"))))
    billed_in = max(0, input_tokens - cached_tokens)
    billed_out = output_tokens + reasoning_tokens
    rates = _rates_for(model, costs)
    total = (
        billed_in * rates["input"]
        + billed_out * rates["output"]
        + cached_tokens * rates["cache_read"]
    )
    return total / 1_000_000.0


def _first_typed_dict(value: Any) -> dict[str, Any]:
    if isinstance(value, dict):
        if isinstance(value.get("type"), str):
            return value
        for nested in value.values():
            found = _first_typed_dict(nested)
            if found:
                return found
    elif isinstance(value, list):
        for nested in value:
            found = _first_typed_dict(nested)
            if found:
                return found
    return {}


def _item_payload(event: dict[str, Any]) -> dict[str, Any]:
    for key in ("item", "payload"):
        payload = event.get(key)
        if isinstance(payload, dict):
            found = _first_typed_dict(payload)
            if found:
                return found
    return {}


def _looks_like_path(value: str, *, allow_bare: bool) -> bool:
    text = _string(value)
    if not text or "\n" in text or "\r" in text or text in (".", "..", "/dev/null"):
        return False
    if "/" in text or "\\" in text or "." in os.path.basename(text):
        return True
    return allow_bare and " " not in text and "\t" not in text


def _collect_paths(value: Any, files: set[str]) -> None:
    if isinstance(value, dict):
        for key, nested in value.items():
            if key in PATH_KEYS and isinstance(nested, str) and _looks_like_path(
                nested, allow_bare=key not in GENERIC_PATH_KEYS
            ):
                files.add(_string(nested))
            _collect_paths(nested, files)
    elif isinstance(value, list):
        for nested in value:
            _collect_paths(nested, files)


def _collect_diff_paths(text: str, files: set[str]) -> None:
    for raw_line in text.splitlines():
        line = raw_line.strip()
        for prefix in ("+++ b/", "--- a/"):
            if line.startswith(prefix) and len(line) > len(prefix):
                path = line[len(prefix):].strip()
                if path and path != "/dev/null":
                    files.add(path)
        if line.startswith("diff --git "):
            parts = line.split()
            if len(parts) >= 4:
                for part in parts[2:4]:
                    if part.startswith(("a/", "b/")) and len(part) > 2:
                        files.add(part[2:])


def _files_from_item(item: dict[str, Any]) -> list[str]:
    files: set[str] = set()
    _collect_paths(item, files)
    for key in ("patch", "diff", "text"):
        value = item.get(key)
        if isinstance(value, str):
            _collect_diff_paths(value, files)
    return sorted(files)


def _mcp_name(item: dict[str, Any]) -> str:
    server = _string(item.get("server") or item.get("mcp_server"))
    tool = _string(
        item.get("tool_name")
        or item.get("tool")
        or item.get("name")
        or _dict(item.get("call")).get("name")
        or _dict(item.get("tool_call")).get("name")
    )
    if server and tool:
        return f"mcp:{server}/{tool}"
    if tool:
        return f"mcp:{tool}"
    if server:
        return f"mcp:{server}"
    return "mcp"


def _tool_name(item: dict[str, Any]) -> str:
    item_type = _string(item.get("type"))
    if not item_type or item_type in TOOLLESS_ITEM_TYPES:
        return ""
    if item_type == "command_execution":
        return "shell"
    if item_type in FILE_ITEM_TYPES:
        return "file edit"
    if item_type == "mcp_tool_call":
        return _mcp_name(item)
    return item_type


def parse_stream(stream_path: str) -> dict[str, Any]:
    """Parse a codex JSONL stream into usage + activity summaries."""
    activity = _empty_activity()
    if not stream_path or not os.path.isfile(stream_path):
        return activity
    return _parse_streams([stream_path])


def _stream_paths(run_dir: str) -> list[str]:
    paths = []
    for name in ("stream.jsonl", "resume-stream.jsonl"):
        path = os.path.join(run_dir, name)
        if os.path.isfile(path):
            paths.append(path)
    return paths


def _parse_streams(stream_paths: list[str]) -> dict[str, Any]:
    activity = _empty_activity()
    if not stream_paths:
        return activity

    usage = _zero_usage()
    tool_counts: Counter[str] = Counter()
    files: set[str] = set()
    items = 0

    for stream_path in stream_paths:
        try:
            with open(stream_path, encoding="utf-8") as handle:
                for raw_line in handle:
                    line = raw_line.strip()
                    if not line:
                        continue
                    try:
                        event = json.loads(line)
                    except (TypeError, ValueError):
                        continue
                    if not isinstance(event, dict):
                        continue

                    event_type = _string(event.get("type"))
                    if event_type == "turn.completed":
                        usage_payload = event.get("usage")
                        if not isinstance(usage_payload, dict):
                            usage_payload = _dict(_dict(event.get("payload")).get("usage"))
                        _sum_usage(usage, usage_payload)
                        continue

                    if event_type != "item.completed":
                        continue

                    items += 1
                    item = _item_payload(event)
                    tool_name = _tool_name(item)
                    if tool_name:
                        tool_counts[tool_name] += 1
                    if _string(item.get("type")) in FILE_ITEM_TYPES:
                        files.update(_files_from_item(item))
        except OSError:
            continue

    tools = [
        {"name": name, "count": count}
        for name, count in sorted(tool_counts.items(), key=lambda item: (-item[1], item[0]))
    ]
    file_list = sorted(files)
    return {
        "usage": usage,
        "tools": tools,
        "files": file_list,
        "items": items,
        "summary": f"{items} items · {len(tools)} tools · {len(file_list)} files",
    }


def run_cost(run_dir: str, model: Any, costs: dict[str, Any]) -> float:
    """Compute a delegated run's cost directly from its stream usage."""
    if not run_dir:
        return 0.0
    activity = _parse_streams(_stream_paths(run_dir))
    if activity == _empty_activity():
        return 0.0
    return cost_for(model, activity.get("usage"), costs)


def load_span_costs(spans_dir: str) -> dict[str, float]:
    """run_id -> total cost_usd from the DURABLE spans. The stream lives in the
    repo's ephemeral .legion/runs/ and gets cleaned; the span (in
    ~/.claude/logs/legion/spans/) persists. Used as the cost fallback so a run
    whose stream is gone still shows its real cost (sum across resume spans)."""
    costs: dict[str, float] = {}
    if not spans_dir or not os.path.isdir(spans_dir):
        return costs
    for name in sorted(os.listdir(spans_dir)):
        if not name.endswith(".jsonl"):
            continue
        try:
            with open(os.path.join(spans_dir, name), encoding="utf-8") as fh:
                for line in fh:
                    line = line.strip()
                    if not line:
                        continue
                    try:
                        span = json.loads(line)
                    except ValueError:
                        continue
                    rid = span.get("run_id")
                    if isinstance(rid, str):
                        costs[rid] = round(costs.get(rid, 0.0) + _num(span.get("cost_usd")), 6)
        except OSError:
            continue
    return costs


def enrich_run(
    record: dict[str, Any],
    run_dir: str,
    costs: dict[str, Any],
    span_costs: dict[str, float] | None = None,
) -> dict[str, Any]:
    """Attach activity and cost to a registry record. Cost prefers the run's own
    stream usage; when the stream is gone, falls back to the durable span cost."""
    activity = _parse_streams(_stream_paths(run_dir)) if run_dir else _empty_activity()
    model = record.get("model") or record.get("resolved_model")
    run_id = record.get("run_id")
    stream_cost = round(cost_for(model, activity.get("usage"), costs), 6)
    cost = stream_cost if stream_cost > 0 else round(_num((span_costs or {}).get(run_id)), 6)
    return {
        "run_id": run_id,
        "model": model,
        "archetype": record.get("archetype"),
        "trace_id": record.get("trace_id"),
        "parent_id": record.get("parent_id"),
        "worktree_dir": record.get("worktree_dir"),
        "branch": record.get("branch"),
        "repo_root": record.get("repo_root"),
        "phase": _dict(record.get("lifecycle")).get("phase"),
        "cost_usd": cost,
        "activity": {
            "tools": activity.get("tools", []),
            "files": activity.get("files", []),
            "items": activity.get("items", 0),
            "summary": activity.get("summary", ""),
        },
    }


def group_by_session(enriched_runs: list[dict[str, Any]]) -> list[dict[str, Any]]:
    """Group enriched runs by SESSION (trace_id) — the fan-out/orchestration that
    spawned them. Each delegate gets its own ephemeral worktree, so grouping by
    worktree_dir is 1:1 and useless; the meaningful unit is the session, which
    lists its agents + the worktrees they ran in.
    """
    grouped: dict[str, dict[str, Any]] = {}
    for run in enriched_runs:
        session = _string(run.get("trace_id")) or _string(run.get("run_id")) or "(standalone)"
        group = grouped.setdefault(
            session,
            {
                "session": session,
                "repo_root": _string(run.get("repo_root")),
                "runs": [],
                "worktrees": set(),
                "run_count": 0,
                "cost_usd": 0.0,
                "statuses": {},
                "_tool_counts": Counter(),
            },
        )
        if not group["repo_root"]:
            group["repo_root"] = _string(run.get("repo_root"))
        group["runs"].append(str(run.get("run_id") or ""))
        wt = _string(run.get("worktree_dir"))
        if wt:
            group["worktrees"].add(wt)
        group["run_count"] += 1
        group["cost_usd"] += _num(run.get("cost_usd"))
        phase = _string(run.get("phase")) or "unknown"
        group["statuses"][phase] = group["statuses"].get(phase, 0) + 1
        for tool in _dict(run.get("activity")).get("tools", []):
            name = _string(_dict(tool).get("name"))
            if name:
                group["_tool_counts"][name] += int(_num(_dict(tool).get("count")))

    results = []
    for group in grouped.values():
        tool_counts = group.pop("_tool_counts")
        group["runs"] = sorted(run_id for run_id in group["runs"] if run_id)
        group["worktrees"] = sorted(group["worktrees"])
        group["cost_usd"] = round(group["cost_usd"], 6)
        group["tools"] = [
            {"name": name, "count": count}
            for name, count in sorted(tool_counts.items(), key=lambda item: (-item[1], item[0]))
        ]
        results.append(group)

    return sorted(results, key=lambda group: (-_num(group.get("cost_usd")), group.get("session") or ""))


def load_registry(directory: str) -> list[dict[str, Any]]:
    """Load run-state records from a Legion registry directory."""
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
        except (OSError, TypeError, ValueError):
            continue
        if isinstance(record, dict) and record.get("schema") == RUN_SCHEMA and record.get("run_id"):
            records.append(record)
    return records


def _resolve_run_dir(record: dict[str, Any], runs_root: str) -> str:
    configured = record.get("run_dir")
    if isinstance(configured, str) and configured.strip():
        return configured
    run_id = _string(record.get("run_id"))
    if run_id and runs_root:
        return os.path.join(runs_root, run_id)
    return ""


def _sorted_tool_totals(tool_counts: Counter[str]) -> dict[str, int]:
    return {
        name: count
        for name, count in sorted(tool_counts.items(), key=lambda item: (-item[1], item[0]))
    }


def build_activity(
    registry_dir: str, runs_root: str, costs_path: str, spans_dir: str | None = None
) -> dict[str, Any]:
    """Build a full activity snapshot for the Legion Console."""
    costs = load_costs(costs_path)
    if spans_dir is None:
        spans_dir = os.path.expanduser("~/.claude/logs/legion/spans")
    span_costs = load_span_costs(spans_dir)
    runs = [
        enrich_run(record, _resolve_run_dir(record, runs_root), costs, span_costs)
        for record in load_registry(registry_dir)
    ]
    runs.sort(key=lambda run: (-_num(run.get("cost_usd")), str(run.get("run_id") or "")))

    total_cost = 0.0
    tool_totals: Counter[str] = Counter()
    for run in runs:
        total_cost += _num(run.get("cost_usd"))
        for tool in _dict(run.get("activity")).get("tools", []):
            name = _string(_dict(tool).get("name"))
            if name:
                tool_totals[name] += int(_num(_dict(tool).get("count")))

    return {
        "generated_at": _iso_utc(),
        "runs": runs,
        "sessions": group_by_session(runs),
        "totals": {
            "cost_usd": round(total_cost, 6),
            "runs": len(runs),
            "tools": _sorted_tool_totals(tool_totals),
        },
    }


def _short(text: Any, width: int) -> str:
    value = str(text or "-")
    if len(value) <= width:
        return value
    if width <= 3:
        return value[:width]
    return value[: width - 3] + "..."


def _format_cost(value: Any) -> str:
    return f"{_num(value):.6f}"


def _render_rows(headers: list[str], rows: list[list[str]], generated_at: str) -> str:
    if not rows:
        return f"generated_at={generated_at}\nNo runs found."

    widths = [
        max(len(headers[idx]), max(len(row[idx]) for row in rows))
        for idx in range(len(headers))
    ]
    lines = [f"generated_at={generated_at}"]
    lines.append(" ".join(headers[idx].ljust(widths[idx]) for idx in range(len(headers))))
    lines.append(" ".join("-" * widths[idx] for idx in range(len(headers))))
    for row in rows:
        lines.append(" ".join(row[idx].ljust(widths[idx]) for idx in range(len(row))))
    return "\n".join(lines)


def _render_runs(snapshot: dict[str, Any]) -> str:
    rows = []
    for run in snapshot.get("runs", []):
        rows.append(
            [
                _short(run.get("run_id"), 16),
                _short(run.get("phase"), 12),
                _short(run.get("model"), 16),
                _format_cost(run.get("cost_usd")),
                _short(_dict(run.get("activity")).get("summary"), 28),
                _short(run.get("worktree_dir") or "(no worktree)", 28),
            ]
        )
    return _render_rows(
        ["run_id", "phase", "model", "cost_usd", "activity", "worktree"],
        rows,
        str(snapshot.get("generated_at") or ""),
    )


def _render_worktrees(snapshot: dict[str, Any]) -> str:
    rows = []
    for group in snapshot.get("sessions", []):
        tools = ", ".join(
            f"{tool.get('name')}:{tool.get('count')}" for tool in group.get("tools", [])[:3]
        ) or "-"
        statuses = ", ".join(
            f"{name}:{count}" for name, count in sorted(_dict(group.get("statuses")).items())
        ) or "-"
        rows.append(
            [
                _short(group.get("session"), 24),
                str(int(_num(group.get("run_count")))),
                str(len(group.get("worktrees", []))),
                _format_cost(group.get("cost_usd")),
                _short(tools, 28),
                _short(statuses, 22),
            ]
        )
    return _render_rows(
        ["session", "runs", "wts", "cost_usd", "tools", "statuses"],
        rows,
        str(snapshot.get("generated_at") or ""),
    )


def _default_registry_dir() -> str:
    return os.path.join(DEFAULT_ROOT, "registry")


def _default_runs_root() -> str:
    return os.path.join(os.getcwd(), ".legion", "runs")


def _default_costs_path() -> str:
    return os.path.abspath(
        os.path.join(HERE, "..", "..", "legion-router", "config", "costs.json")
    )


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="Summarize Legion delegated run activity.")
    parser.add_argument("--registry", default=_default_registry_dir())
    parser.add_argument("--runs", default=_default_runs_root())
    parser.add_argument("--costs", default=_default_costs_path())
    parser.add_argument("--json", action="store_true", help="Print the full snapshot as JSON.")
    parser.add_argument(
        "--worktrees",
        action="store_true",
        help="Print grouped worktree activity instead of per-run rows.",
    )
    args = parser.parse_args(argv)

    snapshot = build_activity(args.registry, args.runs, args.costs)
    if args.json:
        print(json.dumps(snapshot, indent=2, sort_keys=True))
    elif args.worktrees:
        print(_render_worktrees(snapshot))
    else:
        print(_render_runs(snapshot))
    return 0


if __name__ == "__main__":
    sys.exit(main())
