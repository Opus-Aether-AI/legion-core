#!/usr/bin/env python3
"""Self-tuning controller for Legion's pre-cliff context handoff threshold.

The controller does not walk into the context cliff on purpose. It estimates the
cliff from observed bad outcomes, keeps a safety margin below that estimate, and
uses only bounded exploration to reclaim safe headroom.
"""
from __future__ import annotations

import argparse
import glob
import json
import math
import os
import sys
from collections import defaultdict
from typing import Iterable, Mapping, Sequence, TypedDict

HANDOFF_SCHEMA = "legion.handoff.v1"
DEFAULT_RECORDS_GLOB = "~/.claude/logs/legion/handoff/*.jsonl"
DEFAULT_POLICY_PATH = "~/.claude/logs/legion/context-policy.json"

CONT_OK = 0.8
W_FORCED = 10.0
W_CONT = 4.0
W_WASTE = 1.0
COLD_START_T = 0.6
MIN_SAMPLES = 5
EPSILON = 1e-12


class RawTokens(TypedDict, total=False):
    input: int
    cache_read: int
    cache_create: int
    output: int


class HandoffRecord(TypedDict, total=False):
    schema: str
    ts: str
    run_id: str
    context_class: str
    model: str
    runner_type: str
    fill_pct: float
    window_tokens: int
    raw: RawTokens
    trigger_kind: str
    triggered_by_policy: bool
    distance_to_T: float
    handoff_completed: bool
    native_compaction_seen: bool
    degradation_seen: bool
    tool_failure_context_related: bool
    logical_boundary: bool
    operator_abort: bool
    continuity_score: float
    resume_success: bool
    T: float
    floor: float
    ceiling: float
    effective_ceiling: float
    policy_version: int | str
    state_version: int | str


class CostStats(TypedDict):
    forced_rate: float
    cont_fail_rate: float
    token_waste: float


class Proposal(TypedDict):
    key: str
    current_T: float
    cliff: float | None
    cap_T: float
    proposed_T: float
    reason: str
    n_clean: int
    n_forced: int
    n_ambiguous: int


class PolicyEntry(TypedDict, total=False):
    T: float
    floor: float
    ceiling: float
    current_T: float
    proposed_T: float
    decision: str
    reason: str
    cliff: float | None
    cap_T: float
    n_clean: int
    n_forced: int
    n_ambiguous: int
    n_classified: int
    current_cost: float
    proposed_cost: float


Policy = dict[str, PolicyEntry]


def _coerce_float(value: object, default: float = 0.0) -> float:
    if isinstance(value, bool):
        return default
    if isinstance(value, (int, float)):
        number = float(value)
        if math.isfinite(number):
            return number
    return default


def _fill_pct(record: Mapping[str, object]) -> float:
    fill = _coerce_float(record.get("fill_pct"), 0.0)
    if fill < 0.0:
        return 0.0
    if fill > 1.0:
        return 1.0
    return fill


def _continuity_failed(record: Mapping[str, object]) -> bool:
    return (
        not bool(record.get("handoff_completed"))
        or _coerce_float(record.get("continuity_score")) < CONT_OK
        or not bool(record.get("resume_success"))
    )


def policy_key(record: Mapping[str, object]) -> str:
    """Return the policy bucket key for a telemetry record."""
    model = str(record.get("model", ""))
    context_class = str(record.get("context_class", ""))
    runner_type = str(record.get("runner_type") or "default")
    return f"{model}|{context_class}|{runner_type}"


def classify(record: Mapping[str, object]) -> str:
    """Classify a record as clean, forced, or ambiguous."""
    forced = bool(record.get("native_compaction_seen")) or bool(
        record.get("degradation_seen")
    )
    if forced:
        return "forced"
    if (
        bool(record.get("handoff_completed"))
        and _coerce_float(record.get("continuity_score")) >= CONT_OK
        and bool(record.get("resume_success"))
    ):
        return "clean"
    return "ambiguous"


def estimate_cliff(bad_fills: Sequence[float]) -> float | None:
    """Return a conservative p10 estimate from observed bad fills."""
    cleaned = sorted(
        fill
        for fill in (_coerce_float(value, -1.0) for value in bad_fills)
        if 0.0 <= fill <= 1.0
    )
    if not cleaned:
        return None
    rank = max(0, math.ceil(len(cleaned) * 0.10) - 1)
    return cleaned[rank]


def weighted_cost(stats: Mapping[str, object]) -> float:
    """Score a candidate threshold using forced, continuity, and waste costs."""
    forced_rate = _coerce_float(stats.get("forced_rate"))
    cont_fail_rate = _coerce_float(stats.get("cont_fail_rate"))
    token_waste = _coerce_float(stats.get("token_waste"))
    return (
        (W_FORCED * forced_rate)
        + (W_CONT * cont_fail_rate)
        + (W_WASTE * token_waste)
    )


def _bounded(value: float, lower: float, upper: float) -> float:
    return max(lower, min(value, upper))


def _rounded(value: float | None) -> float | None:
    if value is None:
        return None
    return round(value, 6)


def _classified_records(
    records: Sequence[Mapping[str, object]],
) -> list[tuple[Mapping[str, object], str]]:
    outcomes: list[tuple[Mapping[str, object], str]] = []
    for record in records:
        outcome = classify(record)
        if outcome != "ambiguous":
            outcomes.append((record, outcome))
    return outcomes


def _cost_stats(records: Sequence[Mapping[str, object]], threshold: float) -> CostStats:
    classified = _classified_records(records)
    if not classified:
        return {"forced_rate": 0.0, "cont_fail_rate": 0.0, "token_waste": 0.0}

    forced_remaining = 0
    cont_fail_remaining = 0
    token_waste_total = 0.0

    for record, outcome in classified:
        fill = _fill_pct(record)
        would_trigger = fill >= threshold
        if would_trigger:
            token_waste_total += fill - threshold
            continue
        if outcome == "forced":
            forced_remaining += 1
        if _continuity_failed(record):
            cont_fail_remaining += 1

    count = float(len(classified))
    return {
        "forced_rate": forced_remaining / count,
        "cont_fail_rate": cont_fail_remaining / count,
        "token_waste": token_waste_total / count,
    }


def propose_T(
    records_for_class: Sequence[Mapping[str, object]],
    current_T: float,
    floor: float = 0.5,
    ceiling: float = 0.85,
    margin: float = 0.05,
    alpha: float = 0.02,
    beta: float = 0.5,
    k_clean: int = 3,
    cooldown: int = 3,
) -> Proposal:
    """Propose the next threshold for one policy bucket."""
    key = policy_key(records_for_class[0]) if records_for_class else ""
    clean_records: list[Mapping[str, object]] = []
    forced_records: list[Mapping[str, object]] = []
    ambiguous_records: list[Mapping[str, object]] = []
    classified_tail: list[str] = []

    for record in records_for_class:
        outcome = classify(record)
        if outcome == "clean":
            clean_records.append(record)
            classified_tail.append(outcome)
        elif outcome == "forced":
            forced_records.append(record)
            classified_tail.append(outcome)
        else:
            ambiguous_records.append(record)

    cliff = estimate_cliff([_fill_pct(record) for record in forced_records])
    cap_T = (cliff - margin) if cliff is not None else ceiling
    upper = min(ceiling, cap_T if cliff is not None else ceiling)
    if upper < floor:
        upper = floor

    recent_window = records_for_class[-cooldown:] if cooldown > 0 else []
    forced_recently = any(classify(record) == "forced" for record in recent_window)
    last_classified = classified_tail[-k_clean:] if k_clean > 0 else []
    clean_streak = (
        bool(last_classified)
        and len(last_classified) == k_clean
        and all(outcome == "clean" for outcome in last_classified)
    )

    proposed = current_T
    reason = "hold"
    if forced_recently:
        proposed = current_T * beta
        reason = "backoff_recent_forced"
    elif clean_streak and current_T < cap_T:
        proposed = current_T + alpha
        reason = "bounded_exploration"

    proposed = _bounded(proposed, floor, upper)
    return {
        "key": key,
        "current_T": _rounded(current_T) or 0.0,
        "cliff": _rounded(cliff),
        "cap_T": _rounded(cap_T) or 0.0,
        "proposed_T": _rounded(proposed) or 0.0,
        "reason": reason,
        "n_clean": len(clean_records),
        "n_forced": len(forced_records),
        "n_ambiguous": len(ambiguous_records),
    }


def tune(records: Sequence[Mapping[str, object]], policy: Mapping[str, PolicyEntry]) -> Policy:
    """Tune thresholds per policy bucket and return the next policy snapshot."""
    grouped: dict[str, list[Mapping[str, object]]] = defaultdict(list)
    for record in records:
        schema = record.get("schema")
        if schema not in (None, HANDOFF_SCHEMA):
            continue
        grouped[policy_key(record)].append(record)

    result: Policy = {}
    all_keys = set(policy.keys()) | set(grouped.keys())

    for key in sorted(all_keys):
        bucket = sorted(grouped.get(key, []), key=lambda record: str(record.get("ts", "")))
        existing = dict(policy.get(key, {}))
        current_T = _bounded(_coerce_float(existing.get("T"), COLD_START_T), 0.0, 1.0)
        floor = _bounded(_coerce_float(existing.get("floor"), 0.5), 0.0, 1.0)
        ceiling = _bounded(_coerce_float(existing.get("ceiling"), 0.85), 0.0, 1.0)

        proposal = propose_T(bucket, current_T, floor=floor, ceiling=ceiling)
        classified = _classified_records(bucket)
        n_classified = len(classified)
        current_cost = weighted_cost(_cost_stats(bucket, current_T))
        proposed_cost = weighted_cost(_cost_stats(bucket, proposal["proposed_T"]))

        final_T = current_T
        decision = "kept_current"
        if n_classified < MIN_SAMPLES:
            decision = "insufficient_samples"
        elif proposed_cost <= current_cost + EPSILON:
            final_T = proposal["proposed_T"]
            decision = "accepted" if abs(final_T - current_T) > EPSILON else "held"
        else:
            decision = "rejected_cost"

        updated: PolicyEntry = existing
        updated["T"] = final_T
        updated["floor"] = floor
        updated["ceiling"] = ceiling
        updated["current_T"] = current_T
        updated["proposed_T"] = proposal["proposed_T"]
        updated["decision"] = decision
        updated["reason"] = proposal["reason"]
        updated["cliff"] = proposal["cliff"]
        updated["cap_T"] = proposal["cap_T"]
        updated["n_clean"] = proposal["n_clean"]
        updated["n_forced"] = proposal["n_forced"]
        updated["n_ambiguous"] = proposal["n_ambiguous"]
        updated["n_classified"] = n_classified
        updated["current_cost"] = current_cost
        updated["proposed_cost"] = proposed_cost
        result[key] = updated

    return result


def _expand_record_paths(path_spec: str | Sequence[str] | None) -> list[str]:
    specs: list[str]
    if path_spec is None:
        specs = [DEFAULT_RECORDS_GLOB]
    elif isinstance(path_spec, str):
        specs = [path_spec]
    else:
        specs = list(path_spec)

    paths: list[str] = []
    for spec in specs:
        expanded = os.path.expanduser(spec)
        if os.path.isdir(expanded):
            matches = sorted(glob.glob(os.path.join(expanded, "*.jsonl")))
        else:
            matches = sorted(glob.glob(expanded))
        if matches:
            paths.extend(matches)
        elif os.path.isfile(expanded):
            paths.append(expanded)
    return paths


def load_records(path_spec: str | Sequence[str] | None = None) -> list[HandoffRecord]:
    """Load JSONL handoff records from one or more files or globs."""
    records: list[HandoffRecord] = []
    for path in _expand_record_paths(path_spec):
        try:
            with open(path, encoding="utf-8") as handle:
                for line in handle:
                    text = line.strip()
                    if not text:
                        continue
                    try:
                        payload = json.loads(text)
                    except json.JSONDecodeError:
                        continue
                    if isinstance(payload, dict):
                        records.append(payload)
        except OSError:
            continue
    return records


def load_policy(path: str) -> Policy:
    """Load the context policy JSON file, returning an empty policy if absent."""
    expanded = os.path.expanduser(path)
    try:
        with open(expanded, encoding="utf-8") as handle:
            payload = json.load(handle)
    except FileNotFoundError:
        return {}
    except json.JSONDecodeError:
        return {}

    if not isinstance(payload, dict):
        return {}

    policy: Policy = {}
    for key, value in payload.items():
        if isinstance(key, str) and isinstance(value, dict):
            policy[key] = value
    return policy


def save_policy(path: str, policy: Mapping[str, PolicyEntry]) -> None:
    """Write the tuned context policy JSON snapshot."""
    expanded = os.path.expanduser(path)
    parent = os.path.dirname(expanded)
    if parent:
        os.makedirs(parent, exist_ok=True)
    with open(expanded, "w", encoding="utf-8") as handle:
        json.dump(policy, handle, indent=2, sort_keys=True)
        handle.write("\n")


def _iter_report_rows(policy: Mapping[str, PolicyEntry]) -> Iterable[str]:
    for key in sorted(policy.keys()):
        entry = policy[key]
        current_T = _coerce_float(entry.get("current_T"), _coerce_float(entry.get("T")))
        proposed_T = _coerce_float(entry.get("proposed_T"), _coerce_float(entry.get("T")))
        reason = str(entry.get("reason", "hold"))
        decision = str(entry.get("decision", "kept_current"))
        yield (
            f"{key}: {current_T:.3f} -> {proposed_T:.3f}  "
            f"reason={reason}  decision={decision}"
        )


def main(argv: Sequence[str] | None = None) -> int:
    ap = argparse.ArgumentParser(prog="legion-context-tune")
    ap.add_argument("--records", action="append", help="handoff JSONL file or glob")
    ap.add_argument(
        "--policy",
        default=DEFAULT_POLICY_PATH,
        help="policy JSON path "
        f"(default: {DEFAULT_POLICY_PATH})",
    )
    ap.add_argument("--apply", action="store_true", help="write the tuned policy")
    ap.add_argument("--json", action="store_true", help="print JSON instead of text")
    args = ap.parse_args(list(argv) if argv is not None else None)

    records = load_records(args.records)
    current_policy = load_policy(args.policy)
    tuned_policy = tune(records, current_policy)

    if args.apply:
        save_policy(args.policy, tuned_policy)

    if args.json:
        payload = {
            "applied": bool(args.apply),
            "records": len(records),
            "policy_path": os.path.expanduser(args.policy),
            "policy": tuned_policy,
        }
        print(json.dumps(payload, indent=2, sort_keys=True))
        return 0

    print(
        f"legion-context-tune: report-only={str(not args.apply).lower()} "
        f"records={len(records)} policy={os.path.expanduser(args.policy)}"
    )
    for row in _iter_report_rows(tuned_policy):
        print(row)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
