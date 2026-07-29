import importlib.util
import io
import os
import sys

HERE = os.path.dirname(__file__)
_PATH = os.path.join(HERE, "..", "..", "legion-observability", "scripts", "legion-otel-export.py")
_spec = importlib.util.spec_from_file_location("legion_otel_export", _PATH)
oe = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(oe)

_SPAN = {
    "schema": "legion.span.v1", "run_id": "r1", "trace_id": "t1",
    "ts": "2026-06-15T00:00:00Z", "executor": "codex", "model": "test-model-alpha",
    "status": "ok", "cost_usd": 0.1, "duration_ms": 1000, "tokens": {"input_tokens": 5},
}


def test_span_to_otlp_ids_status_and_duration():
    o = oe.span_to_otlp(_SPAN)
    assert len(o["traceId"]) == 32      # 16 bytes hex
    assert len(o["spanId"]) == 16       # 8 bytes hex
    assert o["status"]["code"] == 1     # ok -> OK
    assert int(o["endTimeUnixNano"]) - int(o["startTimeUnixNano"]) == 1000 * 1_000_000


def test_span_to_otlp_failed_status_and_parent():
    o = oe.span_to_otlp({"status": "failed", "ts": "2026-06-15T00:00:00Z", "parent_id": "p"})
    assert o["status"]["code"] == 2
    assert o["parentSpanId"] == oe._hex("p", 8)


def test_trace_id_is_deterministic():
    assert oe.span_to_otlp(_SPAN)["traceId"] == oe.span_to_otlp(_SPAN)["traceId"]


def test_span_to_otlp_tolerates_nonnumeric_duration_and_cost():
    o = oe.span_to_otlp({"schema": "legion.span.v1", "status": "ok",
                         "ts": "2026-06-15T00:00:00Z", "duration_ms": "oops",
                         "cost_usd": {}, "tokens": {}})
    assert o["endTimeUnixNano"] == o["startTimeUnixNano"]  # bad duration -> 0
    cost = [x for x in o["attributes"] if x["key"] == "legion.cost_usd"][0]["value"]["doubleValue"]
    assert cost == 0.0


def test_ts_nanos_naive_is_assumed_utc():
    assert oe._ts_nanos("2026-06-15T12:00:00Z") == oe._ts_nanos("2026-06-15T12:00:00")


def test_build_payload_survives_a_malformed_span():
    p = oe.build_payload([{"schema": "legion.span.v1", "ts": "2026-06-15T00:00:00Z",
                           "status": "ok", "duration_ms": "x", "cost_usd": {}}])
    assert len(p["resourceSpans"][0]["scopeSpans"][0]["spans"]) == 1


def test_build_payload_filters_non_spans():
    p = oe.build_payload([_SPAN, {"schema": "other"}, "garbage"])
    assert len(p["resourceSpans"][0]["scopeSpans"][0]["spans"]) == 1


def test_main_dry_run_prints_payload(capsys, monkeypatch):
    monkeypatch.setattr(sys, "stdin", io.StringIO(_to_jsonl(_SPAN)))
    rc = oe.main(["--dry-run"])
    assert rc == 0
    assert "resourceSpans" in capsys.readouterr().out


def test_main_no_endpoint_is_noop(capsys, monkeypatch):
    monkeypatch.setattr(sys, "stdin", io.StringIO('{"schema":"legion.span.v1"}\n'))
    rc = oe.main(["--endpoint", ""])   # explicit empty endpoint, not dry-run
    assert rc == 0
    assert "no-op" in capsys.readouterr().err


def _to_jsonl(d):
    import json
    return json.dumps(d) + "\n"
