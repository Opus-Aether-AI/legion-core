#!/usr/bin/env python3
"""legion-aggregate — roll up legion.span.v1 JSONL into grouped metrics.

Reads span files (positional paths, or all *.jsonl under --dir / $LEGION_TELEMETRY_DIR)
and prints JSON: per-group count, success_rate, p50/p95 latency, and total cost.
Tolerates malformed lines and missing fields. Pure stdlib — importable for tests.
"""
import argparse
import glob
import json
import math
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import legion_state  # noqa: E402
from legion_executor_registry import is_delegated_executor  # noqa: E402

SUCCESS_STATUSES = {"ok", "over_budget"}


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


def load(paths):
    spans = []
    for p in paths:
        try:
            with open(p) as fh:
                for line in fh:
                    line = line.strip()
                    if not line:
                        continue
                    try:
                        spans.append(json.loads(line))
                    except (ValueError, TypeError):
                        continue  # tolerate garbage lines
        except OSError:
            continue
    return spans


def _num(x):
    # reject bool (True is int 1), NaN (x != x), and non-numerics
    return x if (
        isinstance(x, (int, float)) and not isinstance(x, bool)
        and math.isfinite(x)
    ) else 0


def _provenance_status(span, kind):
    status = span.get(f"{kind}_status")
    value = span.get("cost_usd" if kind == "cost" else "tokens")
    value_is_known = (
        isinstance(value, (int, float)) and not isinstance(value, bool)
        and math.isfinite(value) and value >= 0
    ) if kind == "cost" else isinstance(value, dict)
    if status == "known":
        return "known" if value_is_known else "unknown"
    if status == "partial":
        known_value = span.get("known_cost_usd" if kind == "cost" else "known_usage")
        known_count = span.get("known_cost_attempts" if kind == "cost" else "known_usage_attempts")
        known_value_is_valid = (
            isinstance(known_value, (int, float)) and not isinstance(known_value, bool)
            and math.isfinite(known_value) and known_value >= 0
        ) if kind == "cost" else isinstance(known_value, dict)
        return "partial" if known_value_is_valid and _positive_count(known_count) else "unknown"
    if status in {"unknown", "not_applicable"}:
        return status
    if kind == "cost":
        return "known" if value_is_known else "unknown"
    return "known" if value_is_known else "unknown"


def _merged_status(known, partial, unknown, not_applicable):
    applicable = known + partial + unknown
    if not applicable:
        return "not_applicable"
    if known == applicable + not_applicable:
        return "known"
    if not known and not partial:
        return "unknown"
    return "partial"


def _new_group():
    return {
        "count": 0, "ok": 0, "_known_cost": 0.0, "_dur": [],
        "_cost_known": 0, "_cost_partial": 0, "_cost_unknown": 0, "_cost_na": 0,
        "_usage_known": 0, "_usage_partial": 0, "_usage_unknown": 0, "_usage_na": 0,
        "_known_cost_runs": 0, "_known_usage_runs": 0,
    }


def _record_provenance(group, span):
    cost_status = _provenance_status(span, "cost")
    usage_status = _provenance_status(span, "usage")
    group[f"_cost_{'na' if cost_status == 'not_applicable' else cost_status}"] += 1
    group[f"_usage_{'na' if usage_status == 'not_applicable' else usage_status}"] += 1
    if cost_status == "known":
        group["_known_cost"] += _num(span.get("cost_usd"))
        group["_known_cost_runs"] += 1
    elif cost_status == "partial":
        group["_known_cost"] += _num(span.get("known_cost_usd"))
        group["_known_cost_runs"] += _positive_count(span.get("known_cost_attempts"))
    if usage_status == "known":
        group["_known_usage_runs"] += 1
    elif usage_status == "partial":
        group["_known_usage_runs"] += _positive_count(span.get("known_usage_attempts"))


def _positive_count(value):
    return value if isinstance(value, int) and not isinstance(value, bool) and value > 0 else 0


def _finalize_group(group):
    cost_status = _merged_status(
        group["_cost_known"], group["_cost_partial"], group["_cost_unknown"], group["_cost_na"]
    )
    usage_status = _merged_status(
        group["_usage_known"], group["_usage_partial"], group["_usage_unknown"], group["_usage_na"]
    )
    known_cost = round(group["_known_cost"], 6)
    return {
        "count": group["count"],
        "ok": group["ok"],
        "success_rate": round(group["ok"] / group["count"], 4) if group["count"] else 0,
        "cost_usd": known_cost if cost_status == "known" else None,
        "cost_status": cost_status,
        "known_cost_usd": known_cost if group["_cost_known"] or group["_cost_partial"] else None,
        "known_cost_runs": group["_known_cost_runs"],
        "usage_status": usage_status,
        "known_usage_runs": group["_known_usage_runs"],
        "p50_ms": round(percentile(group["_dur"], 50), 1),
        "p95_ms": round(percentile(group["_dur"], 95), 1),
    }


def _is_synthetic_opus_baseline(span):
    # Accept both the historical marker and the harness-generic
    # `synthetic_primary_baseline` so any primary's baseline is excluded.
    artifacts = span.get("artifacts") or {}
    if not isinstance(artifacts, dict):
        return False
    return artifacts.get("synthetic_opus_baseline") is True or artifacts.get("synthetic_primary_baseline") is True


def _is_rollup_only(span):
    if not isinstance(span, dict):
        return False
    artifacts = span.get("artifacts") or {}
    return isinstance(artifacts, dict) and artifacts.get("rollup_only") is True


def _valid_spans(spans):
    return [
        s for s in spans
        if isinstance(s, dict)
        and s.get("schema") == "legion.span.v1"
        and not _is_rollup_only(s)
    ]


def _archetype_group(span):
    archetype = span.get("archetype")
    if isinstance(archetype, str) and archetype.strip():
        return archetype.strip()
    if is_delegated_executor(span.get("executor")):
        return "unclassified"
    return "not_applicable"


def _classification_payload(total, classified, unclassified, unclassified_cost_group):
    cost = _finalize_group(unclassified_cost_group)
    return {
        "delegated_runs": total,
        "classified_runs": classified,
        "unclassified_runs": unclassified,
        "classification_rate": round(classified / total, 4) if total else 0,
        "unclassified_cost_usd": cost["cost_usd"],
        "unclassified_cost_status": cost["cost_status"],
        "unclassified_known_cost_usd": cost["known_cost_usd"],
        "unclassified_known_cost_runs": cost["known_cost_runs"],
    }


def classification_summary(spans):
    total = classified = unclassified = 0
    unclassified_cost = _new_group()
    for span in spans:
        if (
            not isinstance(span, dict)
            or _is_rollup_only(span)
            or not is_delegated_executor(span.get("executor"))
        ):
            continue
        total += 1
        archetype = span.get("archetype")
        if isinstance(archetype, str) and archetype.strip():
            classified += 1
        else:
            unclassified += 1
            unclassified_cost["count"] += 1
            _record_provenance(unclassified_cost, span)
    return _classification_payload(
        total, classified, unclassified, unclassified_cost
    )


def filter_trace(spans, trace=""):
    valid = _valid_spans(spans)
    available = sorted({s.get("trace_id") for s in valid if s.get("trace_id")})
    if not trace:
        return valid, {"requested": "", "resolved": "", "available": available}
    if trace == "latest":
        resolved = ""
        for span in valid:
            if span.get("trace_id"):
                resolved = str(span.get("trace_id"))
        filtered = [s for s in valid if s.get("trace_id") == resolved] if resolved else []
        return filtered, {"requested": trace, "resolved": resolved, "available": available}
    filtered = [s for s in valid if s.get("trace_id") == trace]
    return filtered, {"requested": trace, "resolved": trace if filtered else "", "available": available}


def aggregate(spans, by="executor", trace=""):
    spans, trace_meta = filter_trace(spans, trace)
    groups = {}
    delegated = classified = unclassified = 0
    unclassified_cost = _new_group()
    for s in spans:
        if _is_synthetic_opus_baseline(s):
            continue
        if is_delegated_executor(s.get("executor")):
            delegated += 1
            archetype = s.get("archetype")
            if isinstance(archetype, str) and archetype.strip():
                classified += 1
            else:
                unclassified += 1
                unclassified_cost["count"] += 1
                _record_provenance(unclassified_cost, s)
        key = _archetype_group(s) if by == "archetype" else (s.get(by) or "unknown")
        g = groups.setdefault(key, _new_group())
        g["count"] += 1
        if s.get("status") in SUCCESS_STATUSES:
            g["ok"] += 1
        _record_provenance(g, s)
        d = _num(s.get("duration_ms", 0))
        if d > 0:
            g["_dur"].append(d)

    out = {}
    total_group = _new_group()
    for k, g in groups.items():
        out[k] = _finalize_group(g)
        for field in total_group:
            if field == "_dur":
                total_group[field].extend(g[field])
            else:
                total_group[field] += g[field]
    total = _finalize_group(total_group)
    return {
        "by": by,
        "trace": trace_meta,
        "groups": out,
        "total": total,
        "classification": _classification_payload(
            delegated, classified, unclassified, unclassified_cost
        ),
    }


def main(argv=None):
    ap = argparse.ArgumentParser(description="Aggregate legion.span.v1 telemetry.")
    ap.add_argument("paths", nargs="*", help="span JSONL files (default: all under --dir)")
    ap.add_argument(
        "--by", default="executor", choices=["executor", "model", "archetype", "status"]
    )
    ap.add_argument("--trace", default="", help="trace id to include, or latest")
    ap.add_argument("--dir", default=os.environ.get(
        "LEGION_TELEMETRY_DIR", os.path.join(legion_state.default_log_root(), "spans")))
    a = ap.parse_args(argv)
    paths = a.paths or sorted(glob.glob(os.path.join(a.dir, "*.jsonl")))
    print(json.dumps(aggregate(load(paths), a.by, a.trace), indent=2))
    return 0


if __name__ == "__main__":
    sys.exit(main())
