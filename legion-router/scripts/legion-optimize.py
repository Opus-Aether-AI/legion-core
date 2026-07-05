#!/usr/bin/env python3
"""legion-optimize — propose advisory routing.toml model changes from telemetry.

Reads `legion.span.v1` JSONL spans, groups delegated runs by archetype/executor/model,
and proposes the cheapest model that clears the quality bar. Acceptance is Pareto-
gated: a change is only accepted if it does not worsen success and does not raise
cost relative to the current routed model.

This tool is report-only. It never writes `routing.toml`.
"""

from __future__ import annotations

import argparse
import ast
import glob
import json
import os
import sys

try:
    import tomllib
except ModuleNotFoundError:  # pragma: no cover - py<3.11
    tomllib = None

sys.path.insert(
    0,
    os.path.abspath(os.path.join(os.path.dirname(__file__), "..", "..", "legion-observability", "scripts")),
)
import legion_state  # noqa: E402

SPAN_SCHEMA = "legion.span.v1"
SUCCESS_STATUSES = {"ok", "over_budget"}
DELEGATED_EXECUTORS = {"codex", "cursor", "claude"}
DEFAULT_SPANS_DIR = legion_state.resolve_state(os.getcwd())["telemetry_dir"]
DEFAULT_ROUTING_FILE = os.path.abspath(
    os.path.join(os.path.dirname(__file__), "..", "config", "routing.toml"))


def _strip_inline_comment(line):
    in_string = False
    escaped = False
    out = []
    for ch in line:
        if escaped:
            out.append(ch)
            escaped = False
            continue
        if ch == "\\" and in_string:
            out.append(ch)
            escaped = True
            continue
        if ch == '"':
            in_string = not in_string
            out.append(ch)
            continue
        if ch == "#" and not in_string:
            break
        out.append(ch)
    return "".join(out).strip()


def _parse_toml_value(raw):
    raw = raw.strip()
    if raw == "[]":
        return []
    if raw.startswith('"') and raw.endswith('"'):
        try:
            return ast.literal_eval(raw)
        except (SyntaxError, ValueError):
            return raw[1:-1]
    if raw in {"true", "false"}:
        return raw == "true"
    try:
        return int(raw)
    except ValueError:
        pass
    try:
        return float(raw)
    except ValueError:
        return raw


def _load_toml_fallback(path):
    table = {}
    current = table
    with open(path, encoding="utf-8") as fh:
        for raw_line in fh:
            line = _strip_inline_comment(raw_line)
            if not line:
                continue
            if line.startswith("[") and line.endswith("]"):
                current = table
                for part in line[1:-1].split("."):
                    current = current.setdefault(part, {})
                continue
            if "=" not in line:
                continue
            key, raw_value = line.split("=", 1)
            current[key.strip()] = _parse_toml_value(raw_value)
    return table


def percentile(values, p):
    if not values:
        return 0.0
    s = sorted(values)
    k = (len(s) - 1) * p / 100.0
    f = int(k)
    c = min(f + 1, len(s) - 1)
    if f == c:
        return float(s[f])
    return s[f] + (s[c] - s[f]) * (k - f)


def _nonnegative_num(value):
    if isinstance(value, bool):
        return None
    if not isinstance(value, (int, float)):
        return None
    if value != value:  # NaN
        return None
    value = float(value)
    return value if value >= 0 else None


def load_spans(spans_dir):
    spans = []
    pattern = os.path.join(os.path.expanduser(str(spans_dir)), "*.jsonl")
    for path in sorted(glob.glob(pattern)):
        try:
            with open(path) as fh:
                for line in fh:
                    line = line.strip()
                    if not line:
                        continue
                    try:
                        span = json.loads(line)
                    except (TypeError, ValueError):
                        continue
                    if not isinstance(span, dict):
                        continue
                    if span.get("schema") != SPAN_SCHEMA:
                        continue
                    if span.get("executor") not in DELEGATED_EXECUTORS:
                        continue
                    archetype = span.get("archetype")
                    if not isinstance(archetype, str) or not archetype.strip():
                        continue
                    spans.append(span)
        except OSError:
            continue
    return spans


def _route_key(executor, model):
    return f"{executor}:{model}"


def stats_by_arch_route(spans):
    grouped = {}
    for span in spans:
        if not isinstance(span, dict):
            continue
        executor = span.get("executor")
        if executor not in DELEGATED_EXECUTORS:
            continue
        archetype = span.get("archetype")
        model = span.get("model")
        if not isinstance(archetype, str) or not archetype.strip():
            continue
        if not isinstance(model, str) or not model:
            continue
        route = _route_key(executor, model)
        bucket = grouped.setdefault(archetype, {}).setdefault(
            route,
            {
                "runs": 0,
                "_success": 0,
                "_cost": 0.0,
                "_dur": [],
                "_executor": executor,
                "_model": model,
            },
        )
        bucket["runs"] += 1
        if span.get("status") in SUCCESS_STATUSES:
            bucket["_success"] += 1
        cost = _nonnegative_num(span.get("cost_usd"))
        bucket["_cost"] += 0.0 if cost is None else cost
        duration = _nonnegative_num(span.get("duration_ms"))
        if duration is not None:
            bucket["_dur"].append(duration)

    out = {}
    for archetype, models in grouped.items():
        out[archetype] = {}
        for route, bucket in models.items():
            runs = bucket["runs"]
            durs = bucket["_dur"]
            out[archetype][route] = {
                "executor": bucket["_executor"],
                "model": bucket["_model"],
                "runs": runs,
                "success_rate": round(bucket["_success"] / runs, 4) if runs else 0.0,
                "mean_cost": round(bucket["_cost"] / runs, 6) if runs else 0.0,
                "p50_ms": round(percentile(durs, 50), 1),
                "p95_ms": round(percentile(durs, 95), 1),
            }
    return out


def stats_by_arch_model(spans):
    """Compatibility view keyed by model for callers that only inspect Codex stats."""
    out = {}
    for archetype, routes in stats_by_arch_route(spans).items():
        out[archetype] = {}
        for stats in routes.values():
            if stats.get("executor") == "codex":
                out[archetype][stats["model"]] = {
                    key: value
                    for key, value in stats.items()
                    if key not in {"executor", "model"}
                }
    return out


def load_routing(path):
    if not path:
        return {}
    path = os.path.expanduser(str(path))
    if not os.path.exists(path):
        return {}
    if tomllib is None:
        table = _load_toml_fallback(path)
    else:
        with open(path, "rb") as fh:
            table = tomllib.load(fh)
    archetypes = table.get("archetypes") or {}
    out = {}
    for name, cfg in archetypes.items():
        if not isinstance(cfg, dict):
            continue
        out[name] = {"model": cfg.get("model"), "executor": cfg.get("executor")}
    return out


def _normalize_route_stats(stats_for_arch, default_executor):
    out = {}
    for key, stats in (stats_for_arch or {}).items():
        if not isinstance(stats, dict):
            continue
        executor = stats.get("executor") or default_executor
        model = stats.get("model") or key
        if not executor or not model:
            continue
        route = _route_key(executor, model)
        item = dict(stats)
        item["executor"] = executor
        item["model"] = model
        out[route] = item
    return out


def _eligible_routes(stats_for_arch, min_samples):
    return {
        route: stats
        for route, stats in (stats_for_arch or {}).items()
        if isinstance(stats, dict) and stats.get("runs", 0) >= min_samples
    }


def _pick_lowest_cost(candidates):
    return min(
        candidates,
        key=lambda route: (
            candidates[route]["mean_cost"],
            -candidates[route]["success_rate"],
            candidates[route].get("executor", ""),
            candidates[route].get("model", route),
        ),
    )


def propose(
    stats_for_arch,
    current_model,
    *,
    current_executor="codex",
    min_samples=5,
    bar_slack=0.02,
    cost_eps=1e-9,
    allow_executor_switch=False,
):
    stats_for_arch = _normalize_route_stats(stats_for_arch or {}, current_executor or "codex")
    current_route = (
        _route_key(current_executor, current_model)
        if current_executor and current_model
        else None
    )
    current = stats_for_arch.get(current_route) if current_route else None
    quality_bar = None
    eligible = _eligible_routes(stats_for_arch, min_samples)

    if current is not None:
        quality_bar = round(current["success_rate"] - bar_slack, 4)
    elif eligible:
        quality_bar = max(stats["success_rate"] for stats in eligible.values())

    if not eligible:
        return {
            "current_executor": current_executor,
            "current_model": current_model,
            "proposed_executor": current_executor,
            "proposed_model": current_model,
            "decision": "hold",
            "reason": "insufficient_samples",
            "current_stats": current,
            "proposed_stats": current,
            "quality_bar": quality_bar,
        }

    candidates = {
        route: stats
        for route, stats in eligible.items()
        if quality_bar is not None and stats["success_rate"] >= quality_bar
    }
    if not candidates:
        return {
            "current_executor": current_executor,
            "current_model": current_model,
            "proposed_executor": current_executor,
            "proposed_model": current_model,
            "decision": "hold",
            "reason": "no_pareto_improvement",
            "current_stats": current,
            "proposed_stats": current,
            "quality_bar": quality_bar,
        }

    # Prefer the CHEAPEST candidate that passes the strict Pareto accept gate (success
    # not worse AND cost not higher than current). Picking the cheapest of the whole
    # slack pool first could surface a slightly-worse-but-cheaper model that then fails
    # the gate, wrongly blocking a genuinely Pareto-valid cheaper model.
    def _passes(s):
        return current is None or (
            s["success_rate"] >= current["success_rate"]
            and s["mean_cost"] <= current["mean_cost"] + cost_eps
        )

    acceptable = {
        route: stats
        for route, stats in candidates.items()
        if route != current_route and _passes(stats)
    }
    if acceptable:
        proposed_route = _pick_lowest_cost(acceptable)
        proposed = acceptable[proposed_route]
        if (
            current_executor
            and proposed.get("executor") != current_executor
            and not allow_executor_switch
        ):
            decision = "hold"
            reason = "executor_switch_unsupported"
        else:
            decision = "accept"
            reason = "no_current_model" if current is None else "pareto_improvement"
    else:
        # Nothing clears the gate — surface the cheapest candidate for the report.
        proposed_route = _pick_lowest_cost(candidates)
        proposed = candidates[proposed_route]
        decision = "hold"
        reason = "already_optimal" if proposed_route == current_route else "no_pareto_improvement"

    return {
        "current_executor": current_executor,
        "current_model": current_model,
        "proposed_executor": proposed.get("executor"),
        "proposed_model": proposed.get("model"),
        "decision": decision,
        "reason": reason,
        "current_stats": current,
        "proposed_stats": proposed,
        "quality_bar": quality_bar,
    }


def optimize(spans, routing, *, min_samples=5, bar_slack=0.02, cost_eps=1e-9):
    stats = stats_by_arch_route(spans)
    arches = set(stats)
    for archetype, cfg in (routing or {}).items():
        if isinstance(cfg, dict) and cfg.get("executor") == "self":
            continue
        arches.add(archetype)

    out = {}
    for archetype in sorted(arches):
        route = (routing or {}).get(archetype, {})
        current = route.get("model")
        current_executor = route.get("executor") or "codex"
        out[archetype] = propose(
            stats.get(archetype, {}),
            current,
            current_executor=current_executor,
            min_samples=min_samples,
            bar_slack=bar_slack,
            cost_eps=cost_eps,
        )
    return out


def _format_stats(stats):
    if not stats:
        return "n/a"
    return (
        f'success={stats["success_rate"] * 100:.1f}% '
        f'mean_cost=${stats["mean_cost"]:.4f} '
        f'p50={stats["p50_ms"]:.1f}ms '
        f'p95={stats["p95_ms"]:.1f}ms'
    )


def _build_payload(spans_dir, routing_file, proposals, min_samples):
    return {
        "spans_dir": os.path.expanduser(str(spans_dir)),
        "routing_file": os.path.expanduser(str(routing_file)),
        "min_samples": min_samples,
        "proposals": proposals,
    }


def main(argv=None):
    ap = argparse.ArgumentParser(description="Propose advisory Legion routing model changes.")
    ap.add_argument("--spans", default=DEFAULT_SPANS_DIR)
    ap.add_argument("--routing", default=DEFAULT_ROUTING_FILE)
    ap.add_argument("--json", action="store_true")
    ap.add_argument("--min-samples", type=int, default=5)
    a = ap.parse_args(argv)

    try:
        spans = load_spans(a.spans)
        routing = load_routing(a.routing)
    except (OSError, RuntimeError, ValueError) as e:
        sys.stderr.write(f"legion-optimize: {e}\n")
        return 2

    proposals = optimize(spans, routing, min_samples=a.min_samples)
    payload = _build_payload(a.spans, a.routing, proposals, a.min_samples)
    note = "Advisory only: accepted proposals do not modify routing.toml."

    if a.json:
        print(json.dumps(payload, indent=2, sort_keys=True))
        sys.stderr.write(f"{note}\n")
        return 0

    for archetype, proposal in payload["proposals"].items():
        current_executor = proposal.get("current_executor") or "-"
        proposed_executor = proposal.get("proposed_executor") or "-"
        current_model = proposal.get("current_model") or "-"
        proposed_model = proposal.get("proposed_model") or "-"
        print(
            f"{archetype}: {current_executor}/{current_model} -> "
            f"{proposed_executor}/{proposed_model} "
            f'({proposal["decision"]}, {proposal["reason"]})'
        )
        print(
            f'  current={_format_stats(proposal["current_stats"])} | '
            f'proposed={_format_stats(proposal["proposed_stats"])} | '
            f'quality_bar={proposal["quality_bar"]}'
        )
    print(note)
    return 0


if __name__ == "__main__":
    sys.exit(main())
