#!/usr/bin/env python3
"""legion-otel-export — map legion.span.v1 -> OTLP/HTTP JSON and POST to a collector.

No-op (exit 0) when OTEL_EXPORTER_OTLP_ENDPOINT is unset, so it's safe to wire in
unconditionally. --dry-run prints the OTLP payload instead of POSTing. Pure stdlib;
importable for tests. Turns a multi-agent run (spans sharing trace_id) into a trace tree.
"""
import argparse
import hashlib
import json
import math
import os
import re
import sys
from datetime import datetime, timezone


def _num(x):
    # reject bool / NaN / non-numerics so a malformed span can't crash the export
    return x if (
        isinstance(x, (int, float)) and not isinstance(x, bool) and math.isfinite(x)
    ) else 0


def _nonnegative_number(x):
    return (
        isinstance(x, (int, float)) and not isinstance(x, bool)
        and math.isfinite(x) and x >= 0
    )


def _hex(seed, nbytes):
    return hashlib.sha256(seed.encode()).hexdigest()[: nbytes * 2]


def _positive_int(value):
    return (
        value
        if isinstance(value, int) and not isinstance(value, bool) and value > 0
        else None
    )


def _attempt_identity(span):
    """Return stable provider-attempt identity while preserving legacy IDs."""
    attempt_id = span.get("attempt_id")
    if not isinstance(attempt_id, str) or not attempt_id.strip():
        attempt_id = ""
    else:
        attempt_id = attempt_id.strip()

    ordinal = _positive_int(span.get("attempt_ordinal"))
    if ordinal is None:
        # Accept early producers that copied the receipt field verbatim.
        ordinal = _positive_int(span.get("ordinal"))

    receipt = ""
    artifacts = span.get("artifacts")
    if isinstance(artifacts, dict):
        candidate = artifacts.get("attempt_receipt")
        if isinstance(candidate, str) and candidate.strip():
            receipt = candidate.strip()
            if ordinal is None:
                match = re.search(r"(?:^|/)attempt-(\d+)\.json$", receipt)
                if match:
                    ordinal = int(match.group(1))

    parts = []
    if attempt_id:
        parts.append(f"id:{attempt_id}")
    if ordinal is not None:
        parts.append(f"ordinal:{ordinal}")
    if receipt:
        parts.append(f"receipt:{receipt}")
    return "|".join(parts), attempt_id, ordinal


def _ts_nanos(ts):
    if not ts:
        return 0
    try:
        dt = datetime.fromisoformat(str(ts).replace("Z", "+00:00"))
        if dt.tzinfo is None:          # naive -> assume UTC (don't drift by host tz)
            dt = dt.replace(tzinfo=timezone.utc)
        return int(dt.timestamp() * 1e9)
    except (ValueError, TypeError):
        return 0


def span_to_otlp(s):
    trace_id = _hex(str(s.get("trace_id") or s.get("run_id") or "legion"), 16)
    legacy_seed = f'{s.get("run_id", "")}{s.get("ts", "")}{s.get("executor", "")}'
    attempt_identity, attempt_id, attempt_ordinal = _attempt_identity(s)
    span_id = _hex(
        legacy_seed if not attempt_identity else f"{legacy_seed}\0{attempt_identity}", 8
    )
    start = _ts_nanos(s.get("ts"))
    dur = _num(s.get("duration_ms"))
    attrs = []

    def a(k, v, kind="stringValue"):
        attrs.append({"key": k, "value": {kind: v}})

    a("legion.executor", str(s.get("executor", "")))
    a("legion.model", str(s.get("model", "")))
    a("legion.status", str(s.get("status", "")))
    if attempt_id:
        a("legion.attempt_id", attempt_id)
    if attempt_ordinal is not None:
        a("legion.attempt_ordinal", attempt_ordinal, "intValue")
    cost_status = str(s.get("cost_status") or (
        "known" if _nonnegative_number(s.get("cost_usd")) else "unknown"
    ))
    usage_status = str(s.get("usage_status") or ("known" if isinstance(s.get("tokens"), dict) else "unknown"))
    a("legion.cost_status", cost_status)
    a("legion.usage_status", usage_status)
    if cost_status == "known" and s.get("cost_usd") is not None:
        a("legion.cost_usd", float(_num(s.get("cost_usd"))), "doubleValue")
    elif cost_status == "partial":
        if s.get("known_cost_usd") is not None:
            a("legion.known_cost_usd", float(_num(s.get("known_cost_usd"))), "doubleValue")
        a("legion.known_cost_attempts", int(_num(s.get("known_cost_attempts"))), "intValue")
    tk = s.get("tokens") or {}
    if isinstance(tk, dict):
        for key in ("input_tokens", "output_tokens", "cached_input_tokens", "reasoning_output_tokens"):
            if key in tk:
                try:
                    a(f"legion.tokens.{key}", int(tk[key]), "intValue")
                except (ValueError, TypeError):
                    pass
    if usage_status == "partial":
        known_usage = s.get("known_usage")
        if isinstance(known_usage, dict):
            a("legion.known_usage", json.dumps(known_usage, sort_keys=True, separators=(",", ":")))
            for key, value in sorted(known_usage.items()):
                try:
                    a(f"legion.known_tokens.{key}", int(value), "intValue")
                except (ValueError, TypeError):
                    pass
        a("legion.known_usage_attempts", int(_num(s.get("known_usage_attempts"))), "intValue")
    parent = s.get("parent_id")
    span = {
        "traceId": trace_id,
        "spanId": span_id,
        "name": f'legion.{s.get("executor", "run")}',
        "kind": 1,
        "startTimeUnixNano": str(start),
        "endTimeUnixNano": str(start + int(dur * 1e6)),
        "attributes": attrs,
        "status": {"code": 1 if s.get("status") == "ok" else 2},
    }
    if parent:
        span["parentSpanId"] = _hex(str(parent), 8)
    return span


def build_payload(spans):
    otlp = [span_to_otlp(s) for s in spans if isinstance(s, dict) and s.get("schema") == "legion.span.v1"]
    return {
        "resourceSpans": [{
            "resource": {"attributes": [{"key": "service.name", "value": {"stringValue": "legion"}}]},
            "scopeSpans": [{"scope": {"name": "legion-observability"}, "spans": otlp}],
        }]
    }


def _read(path):
    spans = []
    fh = sys.stdin if (not path or path == "-") else open(path)
    try:
        for line in fh:
            line = line.strip()
            if not line:
                continue
            try:
                spans.append(json.loads(line))
            except (ValueError, TypeError):
                continue
    finally:
        if fh is not sys.stdin:
            fh.close()
    return spans


def main(argv=None):
    ap = argparse.ArgumentParser()
    ap.add_argument("--file", default="-")
    ap.add_argument("--dry-run", action="store_true")
    ap.add_argument("--endpoint", default=os.environ.get("OTEL_EXPORTER_OTLP_ENDPOINT", ""))
    a = ap.parse_args(argv)
    payload = build_payload(_read(a.file))
    n = len(payload["resourceSpans"][0]["scopeSpans"][0]["spans"])

    if a.dry_run:
        print(json.dumps(payload, indent=2))
        return 0
    if not a.endpoint:
        sys.stderr.write("OTEL_EXPORTER_OTLP_ENDPOINT unset — no-op (use --dry-run to preview)\n")
        return 0
    if n == 0:
        sys.stderr.write("no spans to export\n")
        return 0

    import urllib.request
    url = a.endpoint.rstrip("/") + "/v1/traces"
    req = urllib.request.Request(
        url, data=json.dumps(payload).encode(),
        headers={"content-type": "application/json"}, method="POST")
    try:
        with urllib.request.urlopen(req, timeout=10) as r:
            sys.stderr.write(f"exported {n} span(s) -> {url} ({r.status})\n")
        return 0
    except Exception as e:  # noqa: BLE001 - network failures shouldn't traceback
        sys.stderr.write(f"otel export failed: {e}\n")
        return 1


if __name__ == "__main__":
    sys.exit(main())
