#!/usr/bin/env python3
"""legion-aggregate — roll up legion.span.v1 JSONL into per-executor metrics.

Reads span files (positional paths, or all *.jsonl under --dir / $LEGION_TELEMETRY_DIR)
and prints JSON: per-group count, success_rate, p50/p95 latency, and total cost.
Tolerates malformed lines and missing fields. Pure stdlib — importable for tests.
"""
import argparse
import glob
import json
import os
import sys


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
    return x if isinstance(x, (int, float)) and not isinstance(x, bool) and x == x else 0


def _is_synthetic_opus_baseline(span):
    artifacts = span.get("artifacts") or {}
    return isinstance(artifacts, dict) and artifacts.get("synthetic_opus_baseline") is True


def _valid_spans(spans):
    return [s for s in spans if isinstance(s, dict) and s.get("schema") == "legion.span.v1"]


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
    for s in spans:
        if _is_synthetic_opus_baseline(s):
            continue
        key = s.get(by) or "unknown"
        g = groups.setdefault(key, {"count": 0, "ok": 0, "cost_usd": 0.0, "_dur": []})
        g["count"] += 1
        if s.get("status") == "ok":
            g["ok"] += 1
        g["cost_usd"] += _num(s.get("cost_usd", 0))
        d = _num(s.get("duration_ms", 0))
        if d > 0:
            g["_dur"].append(d)

    out = {}
    total = {"count": 0, "ok": 0, "cost_usd": 0.0}
    for k, g in groups.items():
        durs = g.pop("_dur")
        out[k] = {
            "count": g["count"],
            "ok": g["ok"],
            "success_rate": round(g["ok"] / g["count"], 4) if g["count"] else 0,
            "cost_usd": round(g["cost_usd"], 6),
            "p50_ms": round(percentile(durs, 50), 1),
            "p95_ms": round(percentile(durs, 95), 1),
        }
        total["count"] += g["count"]
        total["ok"] += g["ok"]
        total["cost_usd"] += g["cost_usd"]
    total["success_rate"] = round(total["ok"] / total["count"], 4) if total["count"] else 0
    total["cost_usd"] = round(total["cost_usd"], 6)
    return {"by": by, "trace": trace_meta, "groups": out, "total": total}


def main(argv=None):
    ap = argparse.ArgumentParser(description="Aggregate legion.span.v1 telemetry.")
    ap.add_argument("paths", nargs="*", help="span JSONL files (default: all under --dir)")
    ap.add_argument("--by", default="executor", choices=["executor", "model", "status"])
    ap.add_argument("--trace", default="", help="trace id to include, or latest")
    ap.add_argument("--dir", default=os.environ.get(
        "LEGION_TELEMETRY_DIR", os.path.expanduser("~/.claude/logs/legion/spans")))
    a = ap.parse_args(argv)
    paths = a.paths or sorted(glob.glob(os.path.join(a.dir, "*.jsonl")))
    print(json.dumps(aggregate(load(paths), a.by, a.trace), indent=2))
    return 0


if __name__ == "__main__":
    sys.exit(main())
