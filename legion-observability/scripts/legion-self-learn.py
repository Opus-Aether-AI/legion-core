#!/usr/bin/env python3
"""Legion self-learning loop for harness entities.

This is intentionally local-first and validation-first:

1. Mine outcomes from durable Legion spans, review verdict artifacts, manual bug
   records, trigger evals, and routing optimizer advice.
2. Attach each outcome to a catalog entity (plugin, skill, command, agent, hook,
   MCP) instead of only to a model route.
3. Write a durable memory/proposal queue every day. This is the safe default the
   daily cron uses.
4. Optionally test source candidates when an operator opts into --apply-source.

The shape is inspired by harness-bench and autoresearch style loops: establish a
baseline, run a bounded experiment, record the score, keep safe improvements, and
discard failed source mutations. Legion already has traces, catalog, trigger eval,
and routing optimizer; this script connects those pieces.
"""

from __future__ import annotations

import argparse
import copy
import concurrent.futures
import glob
import hashlib
import importlib.util
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
from collections import defaultdict
from datetime import datetime, timezone
from typing import Any


SPAN_SCHEMA = "legion.span.v1"
OUTCOME_SCHEMA = "legion.outcome.v1"
MEMORY_SCHEMA = "legion.self-learning.memory.v1"
SCORECARD_SCHEMA = "legion.self-learning.scorecard.v1"
DEFAULT_LOG_ROOT = os.path.expanduser("~/.claude/logs/legion")
SAFE_SOURCE_TYPES = {"skill", "command", "agent", "plugin"}
SUCCESS_STATUSES = {"ok"}
DEFAULT_MIN_SCORE_DELTA = 0.001
SEVERITY_ORDER = {"info": 0, "low": 1, "medium": 2, "high": 3, "critical": 4}
STOPWORDS = {
    "the", "a", "an", "and", "or", "of", "to", "for", "in", "on", "with", "is",
    "are", "be", "this", "that", "it", "as", "at", "by", "from", "into", "via",
    "use", "used", "using", "when", "how", "do", "i", "my", "you", "your", "we",
    "can", "should", "need", "want", "please", "help", "me", "across", "so",
    "also", "etc", "covers", "includes", "plus", "per", "any", "task", "run",
    "review", "fix", "bug", "feature", "code", "files", "repo",
}


def _here() -> str:
    return os.path.dirname(os.path.abspath(__file__))


def _find_marketplace_root(start: str) -> str:
    # Return the OUTERMOST marketplace.json, not the first one going up. When
    # legion-core is vendored (consumer/vendored/legion-core/...), the nearest
    # match is legion-core's OWN marketplace.json; the consumer's sits at the
    # repo root above it. Standalone legion-core has a single match (its root).
    current = os.path.abspath(start)
    match = ""
    while current and current != os.path.dirname(current):
        candidate = os.path.join(current, ".claude-plugin", "marketplace.json")
        if os.path.exists(candidate):
            match = current
        current = os.path.dirname(current)
    return match


def default_repo() -> str:
    # Prefer an explicit marketplace root override, else walk up from the script
    # to the outermost consumer marketplace, else fall back to the standalone core.
    env = (
        os.environ.get("MARKETPLACE_ROOT")
        or os.environ.get("LEGION_ROOT")
        or os.environ.get("LEGION_MARKETPLACE_ROOT")
    )
    if env:
        return os.path.abspath(os.path.expanduser(env))
    walked = _find_marketplace_root(_here())
    if walked:
        return walked
    return os.path.abspath(os.path.join(_here(), "..", ".."))


def _load_module(name: str, path: str):
    spec = importlib.util.spec_from_file_location(name, path)
    if spec is None or spec.loader is None:
        raise RuntimeError(f"could not import {path}")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def _catalog_module():
    return _load_module("legion_catalog", os.path.join(_here(), "legion-catalog.py"))


def _eval_module():
    return _load_module("legion_eval", os.path.join(_here(), "legion-eval.py"))


def _optimize_module(repo: str):
    return _load_module(
        "legion_optimize",
        os.path.join(repo, "legion-router", "scripts", "legion-optimize.py"),
    )


def _iso_utc() -> str:
    return datetime.now(timezone.utc).isoformat().replace("+00:00", "Z")


def _date_utc() -> str:
    return datetime.now(timezone.utc).strftime("%Y-%m-%d")


def _text(value: Any) -> str:
    return value.strip() if isinstance(value, str) else ""


def _dict(value: Any) -> dict[str, Any]:
    return value if isinstance(value, dict) else {}


def _list(value: Any) -> list[Any]:
    return value if isinstance(value, list) else []


def _severity(value: Any, default: str = "medium") -> str:
    text = _text(value).lower()
    if text in SEVERITY_ORDER:
        return text
    if text in {"blocker", "severe"}:
        return "critical"
    if text in {"warn", "warning"}:
        return "medium"
    return default


def _tokenize(text: str) -> set[str]:
    toks = re.split(r"[^a-z0-9]+", (text or "").lower())
    return {tok for tok in toks if len(tok) > 1 and tok not in STOPWORDS}


def _stable_id(parts: list[Any]) -> str:
    raw = json.dumps(parts, sort_keys=True, ensure_ascii=True, default=str)
    return hashlib.sha256(raw.encode("utf-8")).hexdigest()[:16]


def _short(text: str, limit: int = 240) -> str:
    collapsed = " ".join(_text(text).split())
    if len(collapsed) <= limit:
        return collapsed
    return collapsed[: limit - 3].rstrip() + "..."


def _ensure_dir(path: str) -> None:
    os.makedirs(path, exist_ok=True)


def self_learn_dir(log_root: str) -> str:
    return os.path.join(os.path.expanduser(log_root), "self-learn")


def memory_path(log_root: str) -> str:
    return os.path.join(self_learn_dir(log_root), "harness-memory.json")


def experiments_path(log_root: str) -> str:
    return os.path.join(self_learn_dir(log_root), "experiments.md")


def experiment_ledger_path(log_root: str) -> str:
    return os.path.join(self_learn_dir(log_root), "experiments.tsv")


def candidate_pool_path(log_root: str) -> str:
    return os.path.join(self_learn_dir(log_root), "candidate-pool.json")


def outcomes_path(log_root: str) -> str:
    return os.path.join(self_learn_dir(log_root), "outcomes.jsonl")


def daily_report_path(log_root: str, day: str | None = None) -> str:
    return os.path.join(self_learn_dir(log_root), "reports", f"{day or _date_utc()}.json")


def _json_file(path: str) -> Any:
    try:
        with open(path, encoding="utf-8") as handle:
            return json.load(handle)
    except (OSError, ValueError, TypeError):
        return None


def _write_json(path: str, payload: Any) -> None:
    _ensure_dir(os.path.dirname(path))
    with open(path, "w", encoding="utf-8") as handle:
        json.dump(payload, handle, indent=2, sort_keys=True)
        handle.write("\n")


def _append_jsonl(path: str, payload: dict[str, Any]) -> None:
    _ensure_dir(os.path.dirname(path))
    with open(path, "a", encoding="utf-8") as handle:
        handle.write(json.dumps(payload, sort_keys=True, ensure_ascii=False))
        handle.write("\n")


def load_spans(log_root: str, day: str | None = None) -> list[dict[str, Any]]:
    spans: list[dict[str, Any]] = []
    spans_dir = os.environ.get("LEGION_TELEMETRY_DIR") or os.path.join(
        os.path.expanduser(log_root), "spans"
    )
    spans_dir = os.path.expanduser(spans_dir)
    paths = (
        [os.path.join(spans_dir, f"{day}.jsonl")]
        if day
        else sorted(glob.glob(os.path.join(spans_dir, "*.jsonl")))
    )
    for path in paths:
        try:
            with open(path, encoding="utf-8") as handle:
                for line in handle:
                    text = line.strip()
                    if not text:
                        continue
                    try:
                        payload = json.loads(text)
                    except ValueError:
                        continue
                    if isinstance(payload, dict) and payload.get("schema") == SPAN_SCHEMA:
                        spans.append(payload)
        except OSError:
            continue
    return spans


def load_manual_outcomes(log_root: str, day: str | None = None) -> list[dict[str, Any]]:
    path = outcomes_path(log_root)
    out: list[dict[str, Any]] = []
    try:
        with open(path, encoding="utf-8") as handle:
            for line in handle:
                text = line.strip()
                if not text:
                    continue
                try:
                    payload = json.loads(text)
                except ValueError:
                    continue
                if (
                    isinstance(payload, dict)
                    and payload.get("schema") == OUTCOME_SCHEMA
                    and (not day or _text(payload.get("ts")).startswith(day))
                ):
                    out.append(payload)
    except OSError:
        pass
    return out


def build_catalog(repo: str) -> dict[str, Any]:
    return _catalog_module().build_catalog(repo)


def _entity_id(entity: dict[str, Any]) -> str:
    return f"{entity.get('type')}:{entity.get('name')}"


def _entity_index(catalog: dict[str, Any]) -> dict[str, dict[str, Any]]:
    return {
        _entity_id(entity): entity
        for entity in _list(catalog.get("entities"))
        if _text(entity.get("type")) and _text(entity.get("name"))
    }


def _entity_tokens(entity: dict[str, Any]) -> set[str]:
    return _tokenize(
        " ".join(
            [
                _text(entity.get("type")),
                _text(entity.get("name")),
                _text(entity.get("plugin")),
                _text(entity.get("description")),
                os.path.basename(_text(entity.get("source_path"))),
            ]
        )
    )


def infer_entity(text: str, catalog: dict[str, Any]) -> tuple[str, str, float]:
    """Attach free text to the most likely catalog entity.

    Prefer narrower harness entities over plugins when scores tie. This makes
    bugs found in slash commands/agents/skills actionable at the right layer.
    """
    prompt_tokens = _tokenize(text)
    best = ("plugin", "legion-observability", 0.0)
    best_rank = -1
    type_rank = {"command": 5, "agent": 4, "skill": 3, "plugin": 2, "hook": 1, "mcp": 1}
    for entity in _list(catalog.get("entities")):
        etype = _text(entity.get("type"))
        name = _text(entity.get("name"))
        if not etype or not name:
            continue
        tokens = _entity_tokens(entity)
        overlap = prompt_tokens & tokens
        if not overlap:
            continue
        score = float(len(overlap)) + (len(overlap) / max(1, len(prompt_tokens | tokens)))
        rank = type_rank.get(etype, 0)
        if score > best[2] or (score == best[2] and rank > best_rank):
            best = (etype, name, score)
            best_rank = rank
    return best


def _outcome(
    *,
    source: str,
    summary: str,
    evidence: str = "",
    severity: str = "medium",
    target_type: str = "plugin",
    target_name: str = "legion-observability",
    run_id: str = "",
    source_path: str = "",
    metadata: dict[str, Any] | None = None,
) -> dict[str, Any]:
    payload = {
        "schema": OUTCOME_SCHEMA,
        "id": _stable_id([source, target_type, target_name, run_id, summary, evidence]),
        "ts": _iso_utc(),
        "source": source,
        "target_type": target_type,
        "target_name": target_name,
        "severity": _severity(severity),
        "summary": _short(summary, 500),
        "evidence": _short(evidence, 1200),
        "run_id": run_id,
        "source_path": source_path,
        "metadata": metadata or {},
    }
    return payload


def _verdict_outcomes(span: dict[str, Any], catalog: dict[str, Any]) -> list[dict[str, Any]]:
    artifacts = _dict(span.get("artifacts"))
    verdict_path = _text(artifacts.get("verdict"))
    if not verdict_path:
        return []
    verdict = _json_file(os.path.expanduser(verdict_path))
    if not isinstance(verdict, dict):
        if _text(span.get("status")) in SUCCESS_STATUSES:
            return []
        etype, name = target_for_span(span, catalog)
        return [
            _outcome(
                source="review-verdict",
                target_type=etype,
                target_name=name,
                severity="medium",
                summary="Review verdict artifact was referenced but could not be parsed.",
                evidence=verdict_path,
                run_id=_text(span.get("run_id")),
                source_path=verdict_path,
                metadata={"span_status": span.get("status")},
            )
        ]

    findings = _list(verdict.get("findings"))
    verdict_status = _text(verdict.get("verdict")).lower()
    outcomes: list[dict[str, Any]] = []
    if verdict_status in {"request_changes", "fail", "failed", "reject"} and not findings:
        etype, name, _score = infer_entity(
            " ".join([_text(span.get("task")), json.dumps(verdict, sort_keys=True)]),
            catalog,
        )
        outcomes.append(
            _outcome(
                source="review-verdict",
                target_type=etype,
                target_name=name,
                severity="high",
                summary=f"Review verdict requested changes for {span.get('archetype') or 'run'}.",
                evidence=_short(json.dumps(verdict, sort_keys=True), 1000),
                run_id=_text(span.get("run_id")),
                source_path=verdict_path,
                metadata={"verdict": verdict_status},
            )
        )

    for finding in findings:
        if not isinstance(finding, dict):
            continue
        evidence_bits = [
            _text(finding.get("title")),
            _text(finding.get("file")),
            str(finding.get("line") or ""),
            _text(finding.get("detail")),
        ]
        etype, name, _score = infer_entity(
            " ".join([_text(span.get("task")), " ".join(evidence_bits)]),
            catalog,
        )
        outcomes.append(
            _outcome(
                source="review-finding",
                target_type=etype,
                target_name=name,
                severity=_severity(finding.get("severity"), "medium"),
                summary=_text(finding.get("title")) or "Review finding found a harness issue.",
                evidence=" | ".join(bit for bit in evidence_bits if bit),
                run_id=_text(span.get("run_id")),
                source_path=verdict_path,
                metadata={
                    "verdict": verdict_status,
                    "file": finding.get("file"),
                    "line": finding.get("line"),
                },
            )
        )
    return outcomes


def target_for_span(span: dict[str, Any], catalog: dict[str, Any]) -> tuple[str, str]:
    target_type = _text(span.get("target_type"))
    target_name = _text(span.get("target_name"))
    if target_type and target_name:
        return target_type, target_name
    executor = _text(span.get("executor"))
    task = _text(span.get("task")).lower()
    if executor == "codex-review" or task.startswith("review "):
        return "plugin", "legion-router"
    etype, name, _score = infer_entity(_text(span.get("task")), catalog)
    return etype, name


def span_outcomes(spans: list[dict[str, Any]], catalog: dict[str, Any]) -> list[dict[str, Any]]:
    outcomes: list[dict[str, Any]] = []
    for span in spans:
        outcomes.extend(_verdict_outcomes(span, catalog))
        status = _text(span.get("status"))
        if status in SUCCESS_STATUSES:
            continue
        etype, name = target_for_span(span, catalog)
        outcomes.append(
            _outcome(
                source="span-status",
                target_type=etype,
                target_name=name,
                severity="high" if status in {"failed", "error"} else "medium",
                summary=f"Legion run ended with status {status or 'unknown'}.",
                evidence=_short(_text(span.get("task")), 1000),
                run_id=_text(span.get("run_id")),
                metadata={
                    "executor": span.get("executor"),
                    "model": span.get("model"),
                    "archetype": span.get("archetype"),
                    "artifacts": span.get("artifacts"),
                },
            )
        )
    return outcomes


def trigger_eval_outcomes(repo: str, catalog: dict[str, Any]) -> list[dict[str, Any]]:
    evaluator = _eval_module()
    outcomes: list[dict[str, Any]] = []
    for dataset, scope in _eval_datasets(repo):
        if not os.path.exists(dataset):
            continue
        cases = evaluator._load_dataset(dataset)
        targets = evaluator.load_targets(repo, evaluator._scope_for_cases(cases, scope))
        results = [evaluator.evaluate_case(case, targets, 3, 0.5) for case in cases]
        for result in results:
            if result.get("status") == "pass":
                continue
            expect = _text(result.get("expect")) or "legion-observability"
            expect_type = _text(result.get("expect_type")) or "plugin"
            top = result.get("top")
            evidence = {
                "dataset": os.path.basename(dataset),
                "prompt": result.get("prompt"),
                "expect_type": expect_type,
                "expect": expect,
                "got_type": result.get("got_type"),
                "got": result.get("got"),
                "top": top,
            }
            outcomes.append(
                _outcome(
                    source="trigger-eval",
                    target_type=expect_type,
                    target_name=expect,
                    severity="medium" if result.get("status") == "collision" else "high",
                    summary=(
                        f"Trigger eval {result.get('status')}: expected "
                        f"{expect_type}:{expect}, got {result.get('got_type')}:{result.get('got')}."
                    ),
                    evidence=json.dumps(evidence, sort_keys=True),
                    metadata={"status": result.get("status"), "dataset": os.path.basename(dataset)},
                )
            )
    return outcomes


def routing_outcomes(
    repo: str, log_root: str, spans: list[dict[str, Any]] | None = None
) -> list[dict[str, Any]]:
    try:
        optimizer = _optimize_module(repo)
        if spans is None:
            spans = optimizer.load_spans(os.path.join(os.path.expanduser(log_root), "spans"))
        routing = optimizer.load_routing(
            os.path.join(repo, "legion-router", "config", "routing.toml")
        )
        proposals = optimizer.optimize(spans, routing)
    except Exception as exc:  # pragma: no cover - defensive report path
        return [
            _outcome(
                source="routing-optimizer",
                target_type="plugin",
                target_name="legion-router",
                severity="medium",
                summary="Routing optimizer could not run.",
                evidence=str(exc),
            )
        ]

    outcomes: list[dict[str, Any]] = []
    for archetype, proposal in proposals.items():
        if _text(proposal.get("decision")) != "accept":
            continue
        outcomes.append(
            _outcome(
                source="routing-optimizer",
                target_type="plugin",
                target_name="legion-router",
                severity="low",
                summary=(
                    f"Routing optimizer accepts {archetype}: "
                    f"{proposal.get('current_model')} -> {proposal.get('proposed_model')}."
                ),
                evidence=json.dumps(proposal, sort_keys=True),
                metadata={"archetype": archetype, "proposal": proposal},
            )
        )
    return outcomes


def _proc_result(name: str, argv: list[str], repo: str, timeout: int = 60) -> dict[str, Any]:
    try:
        proc = subprocess.run(
            argv,
            cwd=repo,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            timeout=timeout,
        )
    except (OSError, subprocess.TimeoutExpired) as exc:
        return {"name": name, "cmd": argv, "ok": False, "error": str(exc)}
    return {
        "name": name,
        "cmd": argv,
        "ok": proc.returncode == 0,
        "returncode": proc.returncode,
        "stdout": proc.stdout[-20000:],
        "stderr": proc.stderr[-20000:],
    }


def _aggregate_eval_summaries(summaries: list[dict[str, Any]]) -> dict[str, Any]:
    cases = sum(int(summary.get("cases") or 0) for summary in summaries)
    passed = sum(int(summary.get("pass") or 0) for summary in summaries)
    collision = sum(int(summary.get("collision") or 0) for summary in summaries)
    miss = sum(int(summary.get("miss") or 0) for summary in summaries)
    hit_weighted = sum(
        float(summary.get("hit_at_k") or 0.0) * int(summary.get("cases") or 0)
        for summary in summaries
    )
    precision = round(passed / cases, 3) if cases else 0.0
    hit_at_k = round(hit_weighted / cases, 3) if cases else 0.0
    return {
        "cases": cases,
        "pass": passed,
        "collision": collision,
        "miss": miss,
        "precision_at_1": precision,
        "hit_at_k": hit_at_k,
        "pass_rate": precision,
    }


def empty_scorecard(repo: str, *, reason: str = "") -> dict[str, Any]:
    return {
        "schema": SCORECARD_SCHEMA,
        "generated_at": _iso_utc(),
        "repo": os.path.abspath(repo),
        "ok": False,
        "score": 0.0,
        "metrics": {
            "cases": 0,
            "pass": 0,
            "collision": 0,
            "miss": 0,
            "precision_at_1": 0.0,
            "hit_at_k": 0.0,
            "pass_rate": 0.0,
        },
        "checks": [],
        "reason": reason,
    }


def _eval_datasets(repo: str) -> list[tuple[str, str]]:
    eval_dir = os.path.join(repo, "legion-observability", "eval")
    return [
        (os.path.join(eval_dir, "skill-triggering.yaml"), "auto"),
        (os.path.join(eval_dir, "entity-triggering.yaml"), "entity"),
    ]


def run_scorecard(repo: str) -> dict[str, Any]:
    """Run Legion's daily deterministic scorecard.

    This is the local analogue of harness-bench's scorecard run and
    autoresearch's fixed metric run: same datasets, same checks, compact metrics.
    """
    repo = os.path.abspath(repo)
    eval_script = os.path.join(repo, "legion-observability", "scripts", "legion-eval.py")
    doctor_script = os.path.join(repo, "legion-observability", "scripts", "legion-doctor.sh")
    if not os.path.exists(eval_script):
        return empty_scorecard(repo, reason="missing legion-eval")

    checks: list[dict[str, Any]] = []
    summaries: list[dict[str, Any]] = []
    for dataset, scope in _eval_datasets(repo):
        if not os.path.exists(dataset):
            continue
        name = f"legion-eval:{os.path.basename(dataset)}"
        check = _proc_result(
            name,
            [
                sys.executable,
                eval_script,
                "--repo",
                repo,
                "--dataset",
                dataset,
                "--scope",
                scope,
                "--json",
            ],
            repo,
        )
        if check.get("ok"):
            try:
                payload = json.loads(_text(check.get("stdout")))
            except ValueError:
                payload = {}
            summary = _dict(payload.get("summary"))
            check["summary"] = summary
            summaries.append(summary)
        checks.append(check)

    if os.path.exists(doctor_script):
        checks.append(_proc_result("legion-doctor", ["bash", doctor_script, "--repo", repo], repo))

    metrics = _aggregate_eval_summaries(summaries)
    ok = bool(summaries) and all(bool(check.get("ok")) for check in checks)
    return {
        "schema": SCORECARD_SCHEMA,
        "generated_at": _iso_utc(),
        "repo": repo,
        "ok": ok,
        "score": metrics["precision_at_1"] if ok else 0.0,
        "metrics": metrics,
        "checks": checks,
    }


def _score_metric(scorecard: dict[str, Any], key: str) -> float:
    if key == "score":
        try:
            return float(scorecard.get("score") or 0.0)
        except (TypeError, ValueError):
            return 0.0
    try:
        return float(_dict(scorecard.get("metrics")).get(key) or 0.0)
    except (TypeError, ValueError):
        return 0.0


def compare_scorecards(
    baseline: dict[str, Any],
    candidate: dict[str, Any],
    *,
    min_score_delta: float = DEFAULT_MIN_SCORE_DELTA,
) -> dict[str, Any]:
    positive_metrics = ["score", "precision_at_1", "hit_at_k", "pass_rate"]
    delta = round(_score_metric(candidate, "score") - _score_metric(baseline, "score"), 6)
    if not candidate.get("ok"):
        return {
            "status": "crash",
            "decision": "validation_failed",
            "delta": delta,
            "regressions": ["scorecard_ok"],
        }
    regressions = [
        key
        for key in positive_metrics
        if _score_metric(candidate, key) + 1e-9 < _score_metric(baseline, key)
    ]
    if regressions:
        return {
            "status": "discard",
            "decision": "metric_regression",
            "delta": delta,
            "regressions": regressions,
        }
    if delta < min_score_delta:
        return {
            "status": "discard",
            "decision": "score_delta_below_min",
            "delta": delta,
            "regressions": [],
        }
    return {"status": "keep", "decision": "measured_improvement", "delta": delta, "regressions": []}


def dedupe_outcomes(outcomes: list[dict[str, Any]]) -> list[dict[str, Any]]:
    by_id: dict[str, dict[str, Any]] = {}
    for outcome in outcomes:
        oid = _text(outcome.get("id")) or _stable_id([outcome])
        current = by_id.get(oid)
        if current is None:
            by_id[oid] = outcome
            continue
        if SEVERITY_ORDER[_severity(outcome.get("severity"))] > SEVERITY_ORDER[
            _severity(current.get("severity"))
        ]:
            by_id[oid] = outcome
    return sorted(
        by_id.values(),
        key=lambda item: (
            -SEVERITY_ORDER[_severity(item.get("severity"))],
            _text(item.get("target_type")),
            _text(item.get("target_name")),
            _text(item.get("summary")),
        ),
    )


def _marketplace_path_for_entity(entity: dict[str, Any]) -> str:
    source_path = _text(entity.get("source_path"))
    if not source_path:
        return ""
    current = source_path if os.path.isdir(source_path) else os.path.dirname(source_path)
    while current and current != os.path.dirname(current):
        candidate = os.path.join(current, ".claude-plugin", "marketplace.json")
        if os.path.exists(candidate):
            return candidate
        current = os.path.dirname(current)
    return ""


def proposal_for_outcome(outcome: dict[str, Any], catalog: dict[str, Any]) -> dict[str, Any]:
    target_type = _text(outcome.get("target_type")) or "plugin"
    target_name = _text(outcome.get("target_name")) or "legion-observability"
    entity = _entity_index(catalog).get(f"{target_type}:{target_name}", {})
    source = _text(outcome.get("source"))
    source_path = _text(entity.get("source_path"))

    if source == "trigger-eval":
        kind = "trigger_description_fix"
        if target_type == "plugin":
            source_path = _marketplace_path_for_entity(entity) or source_path
        suggested = (
            "Tighten the entity description/frontmatter with distinguishing trigger "
            "terms from the failed prompt, and remove ambiguous generic wording that "
            "overlaps the winning entity."
        )
        validation = "Run legion-eval and require no new miss/collision for this case."
    elif source == "routing-optimizer":
        kind = "routing_policy_update"
        suggested = (
            "Review the accepted routing optimizer delta and update routing.toml only "
            "if the sample count and quality bar are trusted."
        )
        validation = "Run legion-optimize --json and tests/python/test_legion_optimize.py."
    elif source in {"review-finding", "review-verdict"}:
        kind = "review_guardrail"
        suggested = (
            "Add a specific guardrail or checklist item to the target command/agent/skill "
            "so future runs catch this finding before final review."
        )
        validation = "Replay the relevant workflow or run the smallest affected eval/test."
    elif source == "span-status":
        kind = "run_failure_guardrail"
        suggested = (
            "Teach the target harness entity to detect this failure mode early, emit a "
            "clearer artifact, or route to a stronger validator before returning."
        )
        validation = "Run legion-doctor, legion-eval, and a targeted delegated smoke run."
    else:
        kind = "memory_guardrail"
        suggested = (
            "Record the issue as a reusable harness memory and turn it into a source "
            "patch when it repeats or blocks work."
        )
        validation = "Run the target entity's normal validation before source mutation."

    proposal = {
        "id": _stable_id(["proposal", outcome.get("id"), kind]),
        "kind": kind,
        "status": "proposed",
        "target_type": target_type,
        "target_name": target_name,
        "source_path": source_path,
        "summary": outcome.get("summary"),
        "evidence": outcome.get("evidence"),
        "severity": _severity(outcome.get("severity")),
        "suggested_change": suggested,
        "validation": validation,
        "outcome_id": outcome.get("id"),
    }
    return proposal


def trace_contrast(spans: list[dict[str, Any]], catalog: dict[str, Any]) -> dict[str, Any]:
    """Summarize pass/fail patterns by entity for future proposal generation."""
    entities: dict[str, dict[str, Any]] = {}
    for span in spans:
        etype, name = target_for_span(span, catalog)
        key = f"{etype}:{name}"
        entry = entities.setdefault(
            key,
            {
                "target_type": etype,
                "target_name": name,
                "ok": 0,
                "failed": 0,
                "statuses": {},
                "success_examples": [],
                "failure_examples": [],
            },
        )
        status = _text(span.get("status")) or "unknown"
        entry["statuses"][status] = int(entry["statuses"].get(status, 0)) + 1
        bucket = "ok" if status in SUCCESS_STATUSES else "failed"
        entry[bucket] += 1
        examples_key = "success_examples" if bucket == "ok" else "failure_examples"
        if len(entry[examples_key]) < 3:
            entry[examples_key].append(
                {
                    "run_id": span.get("run_id"),
                    "executor": span.get("executor"),
                    "model": span.get("model"),
                    "task": _short(_text(span.get("task")), 220),
                }
            )
    return {"entities": dict(sorted(entities.items()))}


def build_report(
    repo: str,
    log_root: str,
    day: str | None = None,
    *,
    scan_all: bool = False,
    include_processed: bool = False,
) -> dict[str, Any]:
    day = day or _date_utc()
    catalog = build_catalog(repo)
    scan_day = None if scan_all else day
    spans = load_spans(log_root, scan_day)
    outcomes = dedupe_outcomes(
        span_outcomes(spans, catalog)
        + trigger_eval_outcomes(repo, catalog)
        + routing_outcomes(repo, log_root, spans)
        + load_manual_outcomes(log_root, scan_day)
    )
    if not include_processed:
        processed = set(_list(load_memory(log_root).get("processed_outcome_ids")))
        outcomes = [outcome for outcome in outcomes if outcome.get("id") not in processed]
    proposals = [proposal_for_outcome(outcome, catalog) for outcome in outcomes]
    by_entity: dict[str, int] = defaultdict(int)
    for outcome in outcomes:
        by_entity[f"{outcome['target_type']}:{outcome['target_name']}"] += 1
    contrast = trace_contrast(spans, catalog)
    return {
        "schema": "legion.self-learning.report.v1",
        "generated_at": _iso_utc(),
        "day": day,
        "repo": os.path.abspath(repo),
        "log_root": os.path.expanduser(log_root),
        "scan_scope": "all" if scan_all else day,
        "spans": len(spans),
        "catalog_entities": len(_list(catalog.get("entities"))),
        "outcomes": outcomes,
        "proposals": proposals,
        "by_entity": dict(sorted(by_entity.items())),
        "scorecard": run_scorecard(repo),
        "trace_contrast": contrast,
    }


def _empty_memory() -> dict[str, Any]:
    return {
        "schema": MEMORY_SCHEMA,
        "created_at": _iso_utc(),
        "updated_at": _iso_utc(),
        "entities": {},
        "processed_outcome_ids": [],
        "reports": [],
        "candidate_pool": [],
    }


def load_memory(log_root: str) -> dict[str, Any]:
    payload = _json_file(memory_path(log_root))
    if isinstance(payload, dict) and payload.get("schema") == MEMORY_SCHEMA:
        return payload
    return _empty_memory()


def _hint_from_proposal(proposal: dict[str, Any]) -> str:
    return _short(
        f"{proposal.get('summary')} Suggested: {proposal.get('suggested_change')}",
        360,
    )


def apply_memory(report: dict[str, Any], log_root: str) -> dict[str, Any]:
    memory = load_memory(log_root)
    if not isinstance(memory.get("entities"), dict):
        memory["entities"] = {}
    entities = memory["entities"]
    for proposal in _list(report.get("proposals")):
        key = f"{proposal.get('target_type')}:{proposal.get('target_name')}"
        entry = _dict(entities.setdefault(key, {}))
        entry.setdefault("target_type", proposal.get("target_type"))
        entry.setdefault("target_name", proposal.get("target_name"))
        entry["updated_at"] = report.get("generated_at")
        entry.setdefault("proposal_ids", [])
        entry.setdefault("hints", [])
        entry.setdefault("source_paths", [])
        if proposal.get("id") not in entry["proposal_ids"]:
            entry["proposal_ids"].append(proposal.get("id"))
        hint = _hint_from_proposal(proposal)
        if hint and hint not in entry["hints"]:
            entry["hints"].append(hint)
        if proposal.get("source_path") and proposal.get("source_path") not in entry["source_paths"]:
            entry["source_paths"].append(proposal.get("source_path"))
        entry["severity"] = max(
            [proposal.get("severity"), entry.get("severity", "info")],
            key=lambda value: SEVERITY_ORDER[_severity(value, "info")],
        )

    resolved_outcome_ids = _resolved_outcome_ids(report)
    processed = _list(memory.setdefault("processed_outcome_ids", []))
    processed_set = set(processed)
    for outcome in _list(report.get("outcomes")):
        oid = _text(outcome.get("id"))
        if oid and oid in resolved_outcome_ids and oid not in processed_set:
            processed.append(oid)
            processed_set.add(oid)

    candidate_pool = _list(memory.setdefault("candidate_pool", []))
    experiments = _dict(report.get("experiments"))
    for candidate in _list(experiments.get("candidates")):
        candidate_ref = {
            "id": candidate.get("id"),
            "target": candidate.get("target"),
            "status": candidate.get("status"),
            "decision": candidate.get("decision"),
            "delta": candidate.get("delta"),
            "generated_at": experiments.get("generated_at"),
            "proposal_ids": candidate.get("proposal_ids", []),
        }
        if candidate_ref not in candidate_pool:
            candidate_pool.append(candidate_ref)

    reports = _list(memory.setdefault("reports", []))
    report_ref = {
        "generated_at": report.get("generated_at"),
        "outcomes": len(_list(report.get("outcomes"))),
        "proposals": len(_list(report.get("proposals"))),
        "path": daily_report_path(log_root, _text(report.get("day")) or None),
    }
    if report_ref not in reports:
        reports.append(report_ref)
    memory["updated_at"] = report.get("generated_at")
    _write_json(memory_path(log_root), memory)
    append_experiment_log(report, log_root)
    return memory


def append_experiment_log(report: dict[str, Any], log_root: str) -> None:
    path = experiments_path(log_root)
    _ensure_dir(os.path.dirname(path))
    exists = os.path.exists(path)
    with open(path, "a", encoding="utf-8") as handle:
        if not exists:
            handle.write("# Legion Self-Learning Experiments\n\n")
            handle.write(
                "Daily loop: observe spans/evals/review findings -> analyze failures -> "
                "write proposals and memory -> validate before source mutation.\n\n"
            )
        handle.write(f"## {_text(report.get('day')) or _date_utc()} - daily loop\n\n")
        handle.write(f"- Outcomes: {len(_list(report.get('outcomes')))}\n")
        handle.write(f"- Proposals: {len(_list(report.get('proposals')))}\n")
        handle.write(f"- Spans scanned: {report.get('spans')}\n")
        scorecard = _dict(report.get("scorecard"))
        metrics = _dict(scorecard.get("metrics"))
        if scorecard:
            handle.write(
                "- Baseline score: "
                f"{scorecard.get('score', 0)} "
                f"(P@1={metrics.get('precision_at_1', 0)}, "
                f"hit@k={metrics.get('hit_at_k', 0)}, "
                f"doctor={'ok' if _doctor_ok(scorecard) else 'fail'})\n"
            )
        experiments = _dict(report.get("experiments"))
        if experiments:
            handle.write(f"- Experiment status: {experiments.get('status')}\n")
            selected = _text(experiments.get("selected_candidate"))
            if selected:
                handle.write(f"- Selected candidate: `{selected}`\n")
            for candidate in _list(experiments.get("candidates"))[:8]:
                handle.write(
                    f"  - `{candidate.get('id')}` {candidate.get('target')} "
                    f"{candidate.get('status')} ({candidate.get('decision')}), "
                    f"delta={candidate.get('delta')}\n"
                )
        top = sorted(
            _dict(report.get("by_entity")).items(),
            key=lambda item: (-item[1], item[0]),
        )[:8]
        if top:
            handle.write("- Top entities: " + ", ".join(f"{k}={v}" for k, v in top) + "\n")
        handle.write("\n")
    append_experiment_ledger(report, log_root)


def _git_commit(repo: str) -> str:
    try:
        proc = subprocess.run(
            ["git", "-C", repo, "rev-parse", "--short", "HEAD"],
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            timeout=5,
        )
    except (OSError, subprocess.TimeoutExpired):
        return ""
    return proc.stdout.strip() if proc.returncode == 0 else ""


def _tsv(value: Any) -> str:
    return str(value if value is not None else "").replace("\t", " ").replace("\n", " ")


def _doctor_ok(scorecard: dict[str, Any]) -> bool:
    return any(
        check.get("name") == "legion-doctor" and bool(check.get("ok"))
        for check in _list(scorecard.get("checks"))
    )


def _ledger_score_fields(scorecard: dict[str, Any]) -> list[Any]:
    metrics = _dict(scorecard.get("metrics"))
    return [
        metrics.get("cases", 0),
        metrics.get("pass", 0),
        metrics.get("miss", 0),
        metrics.get("collision", 0),
        metrics.get("precision_at_1", 0),
        metrics.get("hit_at_k", 0),
        "1" if _doctor_ok(scorecard) else "0",
    ]


def append_experiment_ledger(report: dict[str, Any], log_root: str) -> None:
    """Append a compact daily scorecard row, inspired by autoresearch results.tsv."""
    path = experiment_ledger_path(log_root)
    _ensure_dir(os.path.dirname(path))
    exists = os.path.exists(path)
    outcomes = len(_list(report.get("outcomes")))
    proposals = len(_list(report.get("proposals")))
    status = "clean" if outcomes == 0 else "proposal"
    description = f"{outcomes} outcome(s), {proposals} proposal(s), {report.get('spans', 0)} span(s)"
    baseline = _dict(report.get("scorecard"))
    rows = [[
        _text(report.get("day")) or _date_utc(),
        _git_commit(_text(report.get("repo"))),
        "baseline",
        "",
        "",
        report.get("spans", 0),
        outcomes,
        proposals,
        *_ledger_score_fields(baseline),
        baseline.get("score", 0),
        "",
        0,
        status,
        "report-only",
        description,
    ]]
    experiments = _dict(report.get("experiments"))
    for candidate in _list(experiments.get("candidates")):
        scorecard = _dict(candidate.get("scorecard"))
        rows.append([
            _text(report.get("day")) or _date_utc(),
            _git_commit(_text(report.get("repo"))),
            "candidate",
            candidate.get("id"),
            candidate.get("target"),
            report.get("spans", 0),
            outcomes,
            proposals,
            *_ledger_score_fields(scorecard),
            _score_metric(baseline, "score"),
            _score_metric(scorecard, "score"),
            candidate.get("delta", 0),
            candidate.get("status"),
            candidate.get("decision"),
            candidate.get("hypothesis") or "",
        ])
    with open(path, "a", encoding="utf-8") as handle:
        if not exists:
            handle.write(
                "date\tcommit\texperiment_id\tcandidate_id\ttarget\tspans\toutcomes\t"
                "proposals\teval_cases\teval_pass\teval_miss\teval_collision\t"
                "precision_at_1\thit_at_k\tdoctor_ok\tbaseline_score\tcandidate_score\t"
                "delta\tstatus\tdecision\tdescription\n"
            )
        for row in rows:
            handle.write("\t".join(_tsv(item) for item in row) + "\n")


def _learned_block_lines(proposals: list[dict[str, Any]]) -> list[str]:
    lines = ["<!-- legion-self-learn:start -->", "## Learned Guardrails", ""]
    for proposal in proposals:
        lines.append(
            f"- [{_date_utc()}] {proposal.get('summary')} "
            f"Validation: {proposal.get('validation')}"
        )
    lines.append("<!-- legion-self-learn:end -->")
    return lines


def _replace_learned_block(text: str, block: str) -> str:
    pattern = re.compile(
        r"\n?<!-- legion-self-learn:start -->.*?<!-- legion-self-learn:end -->\n?",
        re.DOTALL,
    )
    if pattern.search(text):
        return pattern.sub("\n\n" + block.rstrip() + "\n", text).rstrip() + "\n"
    return text.rstrip() + "\n\n" + block.rstrip() + "\n"


def _prompt_keywords(prompt: str, existing: str, limit: int = 10) -> list[str]:
    existing_tokens = _tokenize(existing)
    seen: set[str] = set()
    out: list[str] = []
    for raw in re.split(r"[^a-zA-Z0-9]+", prompt):
        token = raw.lower()
        if len(token) <= 2 or token in STOPWORDS or token in existing_tokens or token in seen:
            continue
        seen.add(token)
        out.append(token)
        if len(out) >= limit:
            break
    return out


def _proposal_prompt(proposal: dict[str, Any]) -> str:
    try:
        evidence = json.loads(_text(proposal.get("evidence")))
    except ValueError:
        return ""
    return _text(_dict(evidence).get("prompt"))


def _apply_marketplace_description_fixes(text: str, proposals: list[dict[str, Any]]) -> str:
    try:
        payload = json.loads(text)
    except ValueError:
        return text
    plugins = payload.get("plugins")
    if not isinstance(plugins, list):
        return text
    changed = False
    for proposal in proposals:
        if _text(proposal.get("kind")) != "trigger_description_fix":
            continue
        target_name = _text(proposal.get("target_name"))
        prompt = _proposal_prompt(proposal)
        if not target_name or not prompt:
            continue
        for plugin in plugins:
            if not isinstance(plugin, dict) or plugin.get("name") != target_name:
                continue
            description = _text(plugin.get("description"))
            keywords = _prompt_keywords(prompt, description)
            if not keywords:
                continue
            hint = " Trigger hints: " + ", ".join(keywords) + "."
            if hint.strip() in description:
                continue
            plugin["description"] = (description.rstrip() + hint).strip()
            changed = True
            break
    if not changed:
        return text
    return json.dumps(payload, indent=2, ensure_ascii=False) + "\n"


def _format_frontmatter_description(value: str, new_inner: str) -> str:
    stripped = value.strip()
    if len(stripped) >= 2 and stripped[0] == stripped[-1] and stripped[0] in {"'", '"'}:
        if stripped[0] == '"':
            return json.dumps(new_inner)
        if "'" not in new_inner:
            return f"'{new_inner}'"
        return json.dumps(new_inner)
    return new_inner


def _replace_frontmatter_description(text: str, new_value: str) -> str:
    match = re.match(r"^(\ufeff?---[ \t]*\r?\n)(.*?)(\r?\n---(?:[ \t]*\r?\n|[ \t]*$))", text, re.DOTALL)
    if not match:
        return text
    body = match.group(2)
    desc = re.search(r"(?m)^(description:\s*)(.+?)\s*$", body)
    if not desc:
        return text
    old_value = desc.group(2)
    formatted = _format_frontmatter_description(old_value, new_value)
    new_body = body[: desc.start()] + f"{desc.group(1)}{formatted}" + body[desc.end():]
    return match.group(1) + new_body + match.group(3) + text[match.end():]


def _frontmatter_description(text: str) -> str:
    match = re.match(r"^\ufeff?---[ \t]*\r?\n(.*?)\r?\n---(?:[ \t]*\r?\n|[ \t]*$)", text, re.DOTALL)
    if not match:
        return ""
    desc = re.search(r"(?m)^description:\s*(.+?)\s*$", match.group(1))
    if not desc:
        return ""
    value = desc.group(1).strip()
    if len(value) >= 2 and value[0] == value[-1] and value[0] in {"'", '"'}:
        try:
            if value[0] == '"':
                return str(json.loads(value))
        except ValueError:
            pass
        return value[1:-1]
    return value


def _apply_markdown_description_fixes(text: str, proposals: list[dict[str, Any]]) -> str:
    description = _frontmatter_description(text)
    if not description:
        return text
    new_description = description
    for proposal in proposals:
        if _text(proposal.get("kind")) != "trigger_description_fix":
            continue
        prompt = _proposal_prompt(proposal)
        if not prompt:
            continue
        keywords = _prompt_keywords(prompt, new_description)
        if not keywords:
            continue
        hint = " Trigger hints: " + ", ".join(keywords) + "."
        if hint.strip() not in new_description:
            new_description = (new_description.rstrip() + hint).strip()
    if new_description == description:
        return text
    return _replace_frontmatter_description(text, new_description)


def _source_path_allowed(path: str, *, repo: str = "", allow_vendored: bool = False) -> bool:
    if not path.endswith((".md", "SKILL.md", "marketplace.json")):
        return False
    if "/vendored/" in path and not allow_vendored:
        return False
    if repo:
        if not _path_in_repo(path, repo):
            return False
        if _path_uses_symlink(path, repo):
            return False
    return True


def apply_source(
    report: dict[str, Any], *, allow_vendored: bool = False
) -> tuple[list[str], dict[str, str]]:
    grouped: dict[str, list[dict[str, Any]]] = defaultdict(list)
    repo = _text(report.get("repo"))
    for proposal in _list(report.get("proposals")):
        source_path = _text(proposal.get("source_path"))
        target_type = _text(proposal.get("target_type"))
        if not source_path or target_type not in SAFE_SOURCE_TYPES:
            continue
        if not _source_path_allowed(source_path, repo=repo, allow_vendored=allow_vendored):
            continue
        grouped[source_path].append(proposal)

    changed: list[str] = []
    originals: dict[str, str] = {}
    try:
        for path, proposals in grouped.items():
            try:
                with open(path, encoding="utf-8") as handle:
                    old_text = handle.read()
            except OSError:
                continue
            if path.endswith("marketplace.json"):
                new_text = _apply_marketplace_description_fixes(old_text, proposals)
            else:
                trigger_proposals = [
                    proposal
                    for proposal in proposals
                    if _text(proposal.get("kind")) == "trigger_description_fix"
                ]
                guardrail_proposals = [
                    proposal
                    for proposal in proposals
                    if _text(proposal.get("kind")) != "trigger_description_fix"
                ]
                new_text = _apply_markdown_description_fixes(old_text, trigger_proposals)
                if guardrail_proposals:
                    block = "\n".join(_learned_block_lines(guardrail_proposals))
                    new_text = _replace_learned_block(new_text, block)
                elif trigger_proposals and new_text == old_text:
                    block = "\n".join(_learned_block_lines(trigger_proposals))
                    new_text = _replace_learned_block(new_text, block)
            if new_text == old_text:
                continue
            originals[path] = old_text
            with open(path, "w", encoding="utf-8") as handle:
                handle.write(new_text)
            changed.append(path)
    except Exception:
        restore_sources(originals)
        raise
    return changed, originals


def restore_sources(originals: dict[str, str]) -> None:
    for path, old_text in originals.items():
        try:
            with open(path, "w", encoding="utf-8") as handle:
                handle.write(old_text)
        except OSError:
            continue


def _is_mutable_proposal(
    proposal: dict[str, Any], *, repo: str = "", allow_vendored: bool = False
) -> bool:
    source_path = _text(proposal.get("source_path"))
    target_type = _text(proposal.get("target_type"))
    if not source_path or target_type not in SAFE_SOURCE_TYPES:
        return False
    return _source_path_allowed(source_path, repo=repo, allow_vendored=allow_vendored)


def candidate_groups(
    report: dict[str, Any],
    *,
    max_candidates: int = 4,
    allow_vendored: bool = False,
) -> list[dict[str, Any]]:
    grouped: dict[str, list[dict[str, Any]]] = defaultdict(list)
    repo = _text(report.get("repo"))
    for proposal in _list(report.get("proposals")):
        if _is_mutable_proposal(proposal, repo=repo, allow_vendored=allow_vendored):
            grouped[_text(proposal.get("source_path"))].append(proposal)
    groups: list[dict[str, Any]] = []
    for source_path, proposals in sorted(grouped.items()):
        target = f"{proposals[0].get('target_type')}:{proposals[0].get('target_name')}"
        groups.append(
            {
                "id": _stable_id(["candidate", source_path, [p.get("id") for p in proposals]]),
                "source_path": source_path,
                "target": target,
                "proposal_ids": [p.get("id") for p in proposals],
                "hypothesis": _short(
                    "; ".join(_text(p.get("suggested_change")) or _text(p.get("summary")) for p in proposals),
                    500,
                ),
                "proposals": proposals,
            }
        )
    if max_candidates > 0:
        return groups[:max_candidates]
    return groups


def _copy_repo_to_candidate(repo: str, destination: str) -> None:
    ignore = shutil.ignore_patterns(
        ".git",
        ".legion",
        "node_modules",
        ".venv",
        "__pycache__",
        ".pytest_cache",
        ".mypy_cache",
        ".ruff_cache",
        "dist",
        "build",
        "coverage",
    )
    shutil.copytree(repo, destination, ignore=ignore)


def _path_in_repo(path: str, repo: str) -> bool:
    try:
        repo_real = os.path.realpath(repo)
        return os.path.commonpath([os.path.realpath(path), repo_real]) == repo_real
    except ValueError:
        return False


def _path_uses_symlink(path: str, repo: str) -> bool:
    if not _path_in_repo(path, repo):
        return False
    repo_abs = os.path.abspath(repo)
    path_abs = os.path.abspath(path)
    try:
        rel = os.path.relpath(path_abs, repo_abs)
    except ValueError:
        return True
    if rel.startswith(".." + os.sep) or rel == "..":
        return True
    current = repo_abs
    for part in rel.split(os.sep):
        if not part or part == ".":
            continue
        current = os.path.join(current, part)
        if os.path.islink(current):
            return True
    return False


def _rebase_path(path: str, source_repo: str, target_repo: str) -> str:
    if not _path_in_repo(path, source_repo):
        return path
    rel = os.path.relpath(os.path.abspath(path), os.path.abspath(source_repo))
    return os.path.join(os.path.abspath(target_repo), rel)


def _report_for_candidate(
    report: dict[str, Any],
    group: dict[str, Any],
    source_repo: str,
    candidate_repo: str,
) -> dict[str, Any]:
    candidate_report = copy.deepcopy(report)
    candidate_report["repo"] = os.path.abspath(candidate_repo)
    proposals = copy.deepcopy(_list(group.get("proposals")))
    for proposal in proposals:
        proposal["source_path"] = _rebase_path(_text(proposal.get("source_path")), source_repo, candidate_repo)
    candidate_report["proposals"] = proposals
    return candidate_report


def _run_one_candidate(
    repo: str,
    report: dict[str, Any],
    group: dict[str, Any],
    baseline: dict[str, Any],
    *,
    allow_vendored: bool,
    min_score_delta: float,
) -> dict[str, Any]:
    temp_root = tempfile.mkdtemp(prefix="legion-self-learn-")
    candidate_repo = os.path.join(temp_root, "repo")
    result = {
        "id": group.get("id"),
        "target": group.get("target"),
        "source_path": group.get("source_path"),
        "proposal_ids": group.get("proposal_ids", []),
        "hypothesis": group.get("hypothesis"),
        "isolation": "copy",
        "status": "crash",
        "decision": "not_run",
        "delta": 0.0,
        "changed_source": [],
    }
    try:
        _copy_repo_to_candidate(repo, candidate_repo)
        candidate_report = _report_for_candidate(report, group, repo, candidate_repo)
        changed, _originals = apply_source(candidate_report, allow_vendored=allow_vendored)
        result["changed_source"] = [
            _rebase_path(path, candidate_repo, repo) if _path_in_repo(path, candidate_repo) else path
            for path in changed
        ]
        if not changed:
            result.update({"status": "discard", "decision": "no_source_change", "scorecard": empty_scorecard(candidate_repo)})
            return result
        scorecard = run_scorecard(candidate_repo)
        decision = compare_scorecards(baseline, scorecard, min_score_delta=min_score_delta)
        result.update(decision)
        result["scorecard"] = scorecard
        return result
    except Exception as exc:  # pragma: no cover - defensive candidate isolation
        result.update({"status": "crash", "decision": "exception", "error": str(exc)})
        return result
    finally:
        shutil.rmtree(temp_root, ignore_errors=True)


def _best_candidate(candidates: list[dict[str, Any]]) -> dict[str, Any] | None:
    kept = [candidate for candidate in candidates if candidate.get("status") == "keep"]
    if not kept:
        return None
    return sorted(
        kept,
        key=lambda item: (
            -float(item.get("delta") or 0.0),
            _text(item.get("target")),
            _text(item.get("source_path")),
        ),
    )[0]


def run_candidate_experiments(
    report: dict[str, Any],
    repo: str,
    *,
    max_candidates: int = 4,
    max_workers: int = 2,
    min_score_delta: float = DEFAULT_MIN_SCORE_DELTA,
    allow_vendored: bool = False,
) -> dict[str, Any]:
    baseline = _dict(report.get("scorecard")) or run_scorecard(repo)
    groups = candidate_groups(report, max_candidates=max_candidates, allow_vendored=allow_vendored)
    result = {
        "schema": "legion.self-learning.experiments.v1",
        "generated_at": _iso_utc(),
        "baseline": baseline,
        "candidates": [],
        "selected_candidate": None,
        "changed_source": [],
        "final": None,
        "rolled_back": False,
    }
    if not groups:
        result["status"] = "no_candidates"
        return result

    worker_count = max(1, min(max_workers, len(groups)))
    if worker_count == 1:
        candidates = [
            _run_one_candidate(
                repo,
                report,
                group,
                baseline,
                allow_vendored=allow_vendored,
                min_score_delta=min_score_delta,
            )
            for group in groups
        ]
    else:
        with concurrent.futures.ThreadPoolExecutor(max_workers=worker_count) as executor:
            futures = [
                executor.submit(
                    _run_one_candidate,
                    repo,
                    report,
                    group,
                    baseline,
                    allow_vendored=allow_vendored,
                    min_score_delta=min_score_delta,
                )
                for group in groups
            ]
            candidates = [future.result() for future in futures]
    result["candidates"] = sorted(candidates, key=lambda item: _text(item.get("id")))

    selected = _best_candidate(result["candidates"])
    if not selected:
        result["status"] = "discarded"
        return result

    selected_ids = set(_list(selected.get("proposal_ids")))
    selected_report = copy.deepcopy(report)
    selected_report["proposals"] = [
        proposal for proposal in _list(report.get("proposals")) if proposal.get("id") in selected_ids
    ]
    selected_report["repo"] = os.path.abspath(repo)
    originals: dict[str, str] = {}
    changed: list[str] = []
    try:
        changed, originals = apply_source(selected_report, allow_vendored=allow_vendored)
        final_scorecard = run_scorecard(repo)
        final_decision = compare_scorecards(baseline, final_scorecard, min_score_delta=min_score_delta)
    except Exception as exc:
        restore_sources(originals)
        result["rolled_back"] = True
        result["status"] = "rolled_back"
        result["final"] = empty_scorecard(repo, reason="final scorecard exception")
        result["final_decision"] = {
            "status": "crash",
            "decision": "exception",
            "delta": 0.0,
            "regressions": ["exception"],
            "error": str(exc),
        }
        result["changed_source"] = []
        return result
    if final_decision.get("status") != "keep":
        restore_sources(originals)
        result["rolled_back"] = True
        result["status"] = "rolled_back"
        result["final_decision"] = final_decision
        changed = []
    else:
        result["status"] = "kept"
        result["selected_candidate"] = selected.get("id")
    result["changed_source"] = changed
    result["final"] = final_scorecard
    return result


def _resolved_outcome_ids(report: dict[str, Any]) -> set[str]:
    experiments = _dict(report.get("experiments"))
    if experiments.get("status") != "kept":
        return set()
    selected = _text(experiments.get("selected_candidate"))
    selected_proposal_ids: set[str] = set()
    for candidate in _list(experiments.get("candidates")):
        if _text(candidate.get("id")) == selected and candidate.get("status") == "keep":
            selected_proposal_ids.update(_text(pid) for pid in _list(candidate.get("proposal_ids")))
            break
    if not selected_proposal_ids:
        return set()
    return {
        _text(proposal.get("outcome_id"))
        for proposal in _list(report.get("proposals"))
        if proposal.get("id") in selected_proposal_ids and _text(proposal.get("outcome_id"))
    }


def validate_source(repo: str) -> dict[str, Any]:
    checks = [
        ["legion-eval", "--repo", repo, "--json"],
        ["legion-doctor", "--repo", repo],
    ]
    results: list[dict[str, Any]] = []
    ok = True
    for argv in checks:
        try:
            proc = subprocess.run(
                argv,
                cwd=repo,
                text=True,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                timeout=60,
            )
        except (OSError, subprocess.TimeoutExpired) as exc:
            ok = False
            results.append({"cmd": argv, "ok": False, "error": str(exc)})
            continue
        cmd_ok = proc.returncode == 0
        ok = ok and cmd_ok
        results.append(
            {
                "cmd": argv,
                "ok": cmd_ok,
                "returncode": proc.returncode,
                "stdout": proc.stdout[-4000:],
                "stderr": proc.stderr[-4000:],
            }
        )
    return {"ok": ok, "checks": results}


def hints(log_root: str, entity: str | None = None, limit: int = 20) -> dict[str, Any]:
    memory = load_memory(log_root)
    entries = _dict(memory.get("entities"))
    if entity:
        entries = {entity: entries.get(entity, {})} if entity in entries else {}
    sorted_entries = sorted(
        entries.items(),
        key=lambda item: (
            -SEVERITY_ORDER[_severity(_dict(item[1]).get("severity"), "info")],
            item[0],
        ),
    )[:limit]
    return {
        "schema": "legion.self-learning.hints.v1",
        "updated_at": memory.get("updated_at"),
        "entities": {key: value for key, value in sorted_entries if value},
    }


def render_hints(payload: dict[str, Any]) -> str:
    entities = _dict(payload.get("entities"))
    if not entities:
        return "No Legion self-learning hints yet."
    lines = [f"Legion self-learning hints (updated {payload.get('updated_at')})"]
    for key, entry in entities.items():
        lines.append(f"\n{key} [{entry.get('severity', 'info')}]")
        for hint in _list(entry.get("hints"))[:5]:
            lines.append(f"- {hint}")
    return "\n".join(lines)


def record_manual_outcome(args: argparse.Namespace) -> dict[str, Any]:
    if ":" in args.entity:
        target_type, target_name = args.entity.split(":", 1)
    else:
        target_type, target_name = "plugin", args.entity
    outcome = _outcome(
        source="manual",
        target_type=target_type,
        target_name=target_name,
        severity=args.severity,
        summary=args.summary,
        evidence=args.evidence or args.source or "",
        source_path=args.source or "",
    )
    _append_jsonl(outcomes_path(args.logs), outcome)
    return outcome


def run_command(args: argparse.Namespace) -> int:
    day = args.day or _date_utc()
    report = build_report(
        args.repo,
        args.logs,
        day,
        scan_all=not bool(args.day),
        include_processed=args.include_processed,
    )
    report_path = daily_report_path(args.logs, day)

    experiments: dict[str, Any] | None = None
    changed: list[str] = []
    if args.apply_source:
        experiments = run_candidate_experiments(
            report,
            args.repo,
            max_candidates=args.max_candidates,
            max_workers=args.max_workers,
            min_score_delta=args.min_score_delta,
            allow_vendored=args.allow_vendored,
        )
        report["experiments"] = experiments
        changed = _list(experiments.get("changed_source"))

    _write_json(report_path, report)

    memory = None
    if args.apply_memory or args.apply_source:
        memory = apply_memory(report, args.logs)

    payload = {
        "report_path": report_path,
        "memory_path": memory_path(args.logs),
        "applied_memory": memory is not None,
        "changed_source": changed,
        "experiments": experiments,
        "scorecard": report.get("scorecard"),
        "summary": {
            "spans": report["spans"],
            "catalog_entities": report["catalog_entities"],
            "outcomes": len(report["outcomes"]),
            "proposals": len(report["proposals"]),
        },
        "by_entity": report["by_entity"],
    }
    if args.json:
        print(json.dumps(payload, indent=2, sort_keys=True))
    elif not args.quiet:
        print(
            "legion-self-learn: "
            f"{payload['summary']['outcomes']} outcomes, "
            f"{payload['summary']['proposals']} proposals, "
            f"memory={'applied' if payload['applied_memory'] else 'report-only'}"
        )
        print(f"report: {payload['report_path']}")
        if payload["applied_memory"]:
            print(f"memory: {payload['memory_path']}")
        if changed:
            print("changed source:")
            for path in changed:
                print(f"  {path}")
    if experiments and experiments.get("status") == "rolled_back":
        return 1
    return 0


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(prog="legion-self-learn")
    sub = parser.add_subparsers(dest="cmd")

    run = sub.add_parser("run", help="mine outcomes and write daily proposals")
    run.add_argument("--repo", default=default_repo())
    run.add_argument("--logs", default=DEFAULT_LOG_ROOT)
    run.add_argument("--day", default="", help="UTC day to score (YYYY-MM-DD, default today)")
    run.add_argument("--apply-memory", action="store_true")
    run.add_argument("--apply-source", action="store_true")
    run.add_argument("--allow-vendored", action="store_true")
    run.add_argument("--include-processed", action="store_true")
    run.add_argument("--max-candidates", type=int, default=4)
    run.add_argument("--max-workers", type=int, default=2)
    run.add_argument("--min-score-delta", type=float, default=DEFAULT_MIN_SCORE_DELTA)
    run.add_argument("--json", action="store_true")
    run.add_argument("--quiet", action="store_true")

    hp = sub.add_parser("hints", help="print active self-learning memory")
    hp.add_argument("--logs", default=DEFAULT_LOG_ROOT)
    hp.add_argument("--entity")
    hp.add_argument("--limit", type=int, default=20)
    hp.add_argument("--json", action="store_true")

    rec = sub.add_parser("record", help="record a bug/failure found by a session")
    rec.add_argument("--logs", default=DEFAULT_LOG_ROOT)
    rec.add_argument("--entity", required=True, help="TYPE:NAME, e.g. command:feature")
    rec.add_argument("--summary", required=True)
    rec.add_argument("--severity", default="medium", choices=sorted(SEVERITY_ORDER))
    rec.add_argument("--source", default="")
    rec.add_argument("--evidence", default="")
    rec.add_argument("--json", action="store_true")

    args = parser.parse_args(argv)
    if args.cmd in (None, "run"):
        if args.cmd is None:
            args = parser.parse_args(["run", *(argv or [])])
        return run_command(args)
    if args.cmd == "hints":
        payload = hints(args.logs, args.entity, args.limit)
        if args.json:
            print(json.dumps(payload, indent=2, sort_keys=True))
        else:
            print(render_hints(payload))
        return 0
    if args.cmd == "record":
        outcome = record_manual_outcome(args)
        if args.json:
            print(json.dumps(outcome, indent=2, sort_keys=True))
        else:
            print(f"recorded {outcome['id']} -> {outcome['target_type']}:{outcome['target_name']}")
        return 0
    parser.print_help()
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
