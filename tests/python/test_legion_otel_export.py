import importlib.util
import io
import json
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


def test_legacy_span_id_remains_byte_compatible_without_attempt_identity():
    expected = oe._hex(f'{_SPAN["run_id"]}{_SPAN["ts"]}{_SPAN["executor"]}', 8)
    assert oe.span_to_otlp(_SPAN)["spanId"] == expected


def test_provider_retries_have_unique_span_ids_for_same_second():
    first = dict(_SPAN, attempt_id="r1-codex-attempt-1", attempt_ordinal=1)
    second = dict(_SPAN, attempt_id="r1-codex-attempt-2", attempt_ordinal=2)

    first_otlp = oe.span_to_otlp(first)
    second_otlp = oe.span_to_otlp(second)
    assert first_otlp["spanId"] != second_otlp["spanId"]
    attributes = {item["key"]: item["value"] for item in second_otlp["attributes"]}
    assert attributes["legion.attempt_id"]["stringValue"] == "r1-codex-attempt-2"
    assert attributes["legion.attempt_ordinal"]["intValue"] == 2


def test_current_attempt_receipt_artifacts_disambiguate_provider_retries():
    first = dict(_SPAN, artifacts={"provider_attempt": True,
                                   "attempt_receipt": "/run/attempt-1.json"})
    second = dict(_SPAN, artifacts={"provider_attempt": True,
                                    "attempt_receipt": "/run/attempt-2.json"})

    first_otlp = oe.span_to_otlp(first)
    second_otlp = oe.span_to_otlp(second)
    assert first_otlp["spanId"] != second_otlp["spanId"]
    attributes = {item["key"]: item["value"] for item in second_otlp["attributes"]}
    assert attributes["legion.attempt_ordinal"]["intValue"] == 2


def test_span_schema_declares_attempt_identity_fields():
    schema_path = os.path.join(
        HERE, "..", "..", "legion-observability", "schema", "legion.span.v1.schema.json"
    )
    with open(schema_path, encoding="utf-8") as handle:
        properties = json.load(handle)["properties"]
    assert properties["attempt_id"]["type"] == ["string", "null"]
    assert properties["attempt_ordinal"]["minimum"] == 1


def test_span_to_otlp_tolerates_nonnumeric_duration_and_cost():
    o = oe.span_to_otlp({"schema": "legion.span.v1", "status": "ok",
                         "ts": "2026-06-15T00:00:00Z", "duration_ms": "oops",
                         "cost_usd": {}, "tokens": {}})
    assert o["endTimeUnixNano"] == o["startTimeUnixNano"]  # bad duration -> 0
    attributes = {item["key"]: item["value"] for item in o["attributes"]}
    assert attributes["legion.cost_status"]["stringValue"] == "unknown"
    assert "legion.cost_usd" not in attributes


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


def test_unknown_metering_is_not_exported_as_free_cost():
    span = oe.span_to_otlp({
        "schema": "legion.span.v1", "run_id": "unknown-metering", "executor": "deepseek",
        "model": "unknown", "status": "ok", "cost_usd": None, "cost_status": "unknown",
        "tokens": None, "usage_status": "unknown",
    })
    attributes = {item["key"]: item["value"] for item in span["attributes"]}
    assert attributes["legion.cost_status"]["stringValue"] == "unknown"
    assert attributes["legion.usage_status"]["stringValue"] == "unknown"
    assert "legion.cost_usd" not in attributes


def test_partial_metering_exports_lower_bound_values_and_counts():
    span = oe.span_to_otlp({
        "schema": "legion.span.v1", "run_id": "partial-metering", "executor": "review",
        "model": "mixed", "status": "ok", "cost_usd": None, "cost_status": "partial",
        "known_cost_usd": 0.25, "known_cost_attempts": 1, "tokens": None,
        "usage_status": "partial", "known_usage": {"input_tokens": 7},
        "known_usage_attempts": 1,
    })
    attributes = {item["key"]: item["value"] for item in span["attributes"]}
    assert "legion.cost_usd" not in attributes
    assert attributes["legion.known_cost_usd"]["doubleValue"] == 0.25
    assert attributes["legion.known_cost_attempts"]["intValue"] == 1
    assert attributes["legion.known_usage"]["stringValue"] == '{"input_tokens":7}'
    assert attributes["legion.known_tokens.input_tokens"]["intValue"] == 7
    assert attributes["legion.known_usage_attempts"]["intValue"] == 1


def _to_jsonl(d):
    return json.dumps(d) + "\n"
