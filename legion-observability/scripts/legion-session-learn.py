#!/usr/bin/env python3
"""Mine recent agent sessions into Legion self-learning outcomes.

This is the layer above "the user noticed a pattern". It scans Claude memories,
Claude/Codex/Cursor JSONL sessions, extracts paragraphs that look like gotchas or
review findings, classifies them into reusable guardrail categories, and can
record those as `legion.outcome.v1` records for `legion-self-learn run`.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import sys
from datetime import datetime, timedelta, timezone
from pathlib import Path
from typing import Any

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import legion_state  # noqa: E402

OUTCOME_SCHEMA = "legion.outcome.v1"
DEFAULT_LOG_ROOT = ""
MAX_BLOCK_CHARS = 20000

STOPWORDS = {
    "a",
    "an",
    "and",
    "for",
    "from",
    "in",
    "of",
    "on",
    "or",
    "the",
    "to",
    "with",
}

RULES = [
    {
        "category": "seam-consumption",
        "entity": "skill:legion-orchestrate",
        "severity": "high",
        "summary": (
            "Require consumption proof for declared seams: an interface is not wired until "
            "a domain path calls it and telemetry/validation proves it."
        ),
        "patterns": [
            r"seams? (are )?wired but dead",
            r"zero domain callers",
            r"defined\+tested but",
            r"not actually consumed",
            r"no real spans? flow",
            r"span sink is wrong",
            r"status .*isn.?t in the canonical enum",
        ],
    },
    {
        "category": "provider-truth-preflight",
        "entity": "skill:legion-orchestrate",
        "severity": "high",
        "summary": (
            "Before deploy or extraction work, verify provider truth directly: Vercel "
            "project root/build settings, aliases, auth token source, basePath, and "
            "private-package access can differ from repo assumptions."
        ),
        "patterns": [
            r"rootDirectory",
            r"buildCommand",
            r"bare .*vercel\\.app .*different",
            r"stale.*VERCEL_TOKEN",
            r"private .*packages?.*401",
            r"GitHub Packages.*403",
            r"preview deploys?.*SSO",
            r"basePath",
            r"Vercel .*Root Directory",
            r"doesn.?t apply",
        ],
    },
    {
        "category": "ci-admin-bypass",
        "entity": "skill:legion-orchestrate",
        "severity": "high",
        "summary": (
            "When admin or bypass merge is used, prove required checks are actually green; "
            "do not treat bypassing review as bypassing CI health."
        ),
        "patterns": [
            r"admin bypass",
            r"admin-merg",
            r"checks? .*GREEN",
            r"silently red",
            r"review required",
            r"required checks?",
            r"validate-installer-coverage",
            r"mergeStateStatus",
        ],
    },
    {
        "category": "visual-delivery-gate",
        "entity": "skill:legion-orchestrate",
        "severity": "medium",
        "summary": (
            "For cinematic/landing/UI work, require visual acceptance evidence across "
            "desktop, mobile, reduced motion, and live deployment before declaring done."
        ),
        "patterns": [
            r"cinematic landing",
            r"Higgsfield",
            r"hero video",
            r"reduced-motion",
            r"screenshot",
            r"viewport",
            r"mobile",
            r"visual",
            r"landing.*feel premium",
            r"scroll-scrubbed",
        ],
    },
    {
        "category": "skill-taxonomy-drift",
        "entity": "plugin:legion-setup",
        "severity": "medium",
        "summary": (
            "New skills must be classified and stamped in the marketplace taxonomy; "
            "otherwise plugin validation and installer coverage fail after merge-base drift."
        ),
        "patterns": [
            r"unclassified skill",
            r"skill taxonomy",
            r"apply-skill-taxonomy",
            r"kind: ability",
            r"validate-plugins.*taxonomy",
        ],
    },
    {
        "category": "repo-extraction-sweep",
        "entity": "skill:legion-orchestrate",
        "severity": "high",
        "summary": (
            "For app extraction or deletion, run a structured sweep: remaining refs, "
            "reverse deps, fixed-version/release config, deploy workflows, auth origins, "
            "lockfile provenance, and provider config."
        ),
        "patterns": [
            r"extraction diff",
            r"missed monorepo references",
            r"release/versioning pitfalls",
            r"deploy/config breakage",
            r"remaining .* refs",
            r"reverse deps",
            r"changeset",
            r"bun\\.lock",
            r"workspace depend",
            r"trusted origins",
        ],
    },
    {
        "category": "user-correction-feedback",
        "entity": "plugin:legion-observability",
        "severity": "medium",
        "roles": ["user"],
        "summary": (
            "Treat explicit user corrections as self-learning feedback: record the "
            "miss, verify the concrete source of truth, and turn repeated misses into "
            "guardrails before similar docs/routing/orchestration work."
        ),
        "patterns": [
            r"\b(you|u) should have\b",
            r"\b(you|u) (missed|forgot|linked|credited|used) (the )?wrong\b",
            r"\bwrong (repo|paper|link|credit|attribution|source)\b",
            r"\bnot (the )?(right|correct) (repo|paper|link|credit|attribution|source)\b",
            r"\bnot what i meant\b",
            r"\bthat(?:'s| is) wrong\b",
            r"\bdid we even refer to\b",
            r"\bi thought\b.*\b(from|was|came from|based on)\b",
            r"\bhow (the hell|did) .* happen(?:ed)?\b",
            r"\bis .*learn(?:ing|in) from this\b",
            r"\bthis (should|needs?) .* learn\b",
        ],
    },
]


def _utc_now() -> datetime:
    return datetime.now(timezone.utc)


def _stable_id(parts: list[Any]) -> str:
    raw = json.dumps(parts, sort_keys=True, ensure_ascii=True, default=str)
    return hashlib.sha256(raw.encode("utf-8")).hexdigest()[:16]


def _short(text: str, limit: int) -> str:
    collapsed = " ".join((text or "").split())
    return collapsed if len(collapsed) <= limit else collapsed[: limit - 3].rstrip() + "..."


def _tokens(text: str) -> set[str]:
    return {
        tok
        for tok in re.split(r"[^a-z0-9]+", (text or "").lower())
        if len(tok) > 1 and tok not in STOPWORDS
    }


def _cutoff(days: int) -> float:
    if days <= 0:
        return 0.0
    return (_utc_now() - timedelta(days=days)).timestamp()


def _iter_files(home: Path, days: int, max_file_mb: float) -> tuple[list[Path], int]:
    cutoff = _cutoff(days)
    max_bytes = int(max_file_mb * 1024 * 1024) if max_file_mb > 0 else 0
    roots = [
        home / ".claude" / "projects",
        home / ".claude" / "plans",
        home / ".codex" / "sessions",
        home / ".cursor",
    ]
    suffixes = {".md", ".txt", ".jsonl", ".json", ".log"}
    out: list[Path] = []
    skipped = 0
    for root in roots:
        if not root.exists():
            continue
        for path in root.rglob("*"):
            if not path.is_file() or path.suffix not in suffixes:
                continue
            try:
                stat = path.stat()
                if cutoff and stat.st_mtime < cutoff:
                    continue
                if max_bytes and stat.st_size > max_bytes and path.suffix != ".jsonl":
                    skipped += 1
                    continue
            except OSError:
                continue
            out.append(path)
    return sorted(out), skipped


def _content_text(content: Any) -> str:
    if isinstance(content, str):
        return content
    if isinstance(content, list):
        parts: list[str] = []
        for item in content:
            if isinstance(item, dict):
                if item.get("type") == "text":
                    parts.append(str(item.get("text") or ""))
                elif item.get("type") == "tool_result":
                    parts.append(str(item.get("content") or ""))
            else:
                parts.append(str(item))
        return "\n".join(parts)
    if isinstance(content, dict):
        for key in ("message", "content", "text", "summary"):
            value = content.get(key)
            text = _content_text(value)
            if text:
                return text
    return ""


def _message_role(obj: dict[str, Any]) -> str:
    message = obj.get("message") if isinstance(obj.get("message"), dict) else {}
    if isinstance(message, dict) and isinstance(message.get("role"), str):
        return str(message["role"]).lower()
    if isinstance(obj.get("role"), str):
        return str(obj["role"]).lower()
    payload = obj.get("payload") if isinstance(obj.get("payload"), dict) else {}
    payload_type = str(payload.get("type") or "").lower()
    if payload_type == "user_message":
        return "user"
    if payload_type == "agent_message":
        return "assistant"
    if isinstance(payload.get("role"), str):
        return str(payload["role"]).lower()
    return ""


def _message_text(obj: dict[str, Any]) -> str:
    message = obj.get("message") if isinstance(obj.get("message"), dict) else {}
    content = message.get("content") if isinstance(message, dict) else None
    text = _content_text(content)
    if text:
        return text
    payload = obj.get("payload") if isinstance(obj.get("payload"), dict) else {}
    text = _content_text(payload)
    if text:
        return text
    for key in ("content", "text", "summary", "message"):
        text = _content_text(obj.get(key))
        if text:
            return text
    return str(obj.get("summary") or "")


def _extract_records(path: Path) -> list[dict[str, str]]:
    if path.suffix == ".jsonl":
        records: list[dict[str, str]] = []
        try:
            with path.open(encoding="utf-8", errors="ignore") as handle:
                for line in handle:
                    try:
                        payload = json.loads(line)
                    except ValueError:
                        continue
                    if isinstance(payload, dict):
                        block = _message_text(payload)
                        if block:
                            records.append(
                                {
                                    "text": block[:MAX_BLOCK_CHARS],
                                    "role": _message_role(payload),
                                }
                            )
        except OSError:
            return []
        return records

    try:
        text = path.read_text(encoding="utf-8", errors="ignore")
    except OSError:
        return []
    if path.suffix == ".json":
        try:
            payload = json.loads(text)
        except ValueError:
            return []
        if isinstance(payload, dict):
            block = _message_text(payload) or json.dumps(payload, sort_keys=True)
            return [{"text": block[:MAX_BLOCK_CHARS], "role": _message_role(payload)}]
        return []
    return [
        {"text": part[:MAX_BLOCK_CHARS], "role": ""}
        for part in re.split(r"\n\s*\n", text)
        if part.strip()
    ]


def _extract_blocks(path: Path) -> list[str]:
    return [record["text"] for record in _extract_records(path)]


def _matches_query(block: str, source_path: Path, queries: list[str]) -> bool:
    if not queries:
        return True
    lower = f"{source_path} {block}".lower()
    return any(query.lower() in lower for query in queries)


def classify_block(block: str, role: str = "") -> list[dict[str, Any]]:
    hits: list[dict[str, Any]] = []
    for rule in RULES:
        roles = {str(item).lower() for item in rule.get("roles", [])}
        if roles and role.lower() not in roles:
            continue
        matched = [
            pat
            for pat in rule["patterns"]
            if re.search(str(pat), block, flags=re.IGNORECASE | re.DOTALL)
        ]
        if matched:
            hits.append({"rule": rule, "patterns": matched})
    return hits


def scan(
    home: Path,
    *,
    days: int = 3,
    queries: list[str] | None = None,
    limit: int = 5,
    max_file_mb: float = 8.0,
) -> dict[str, Any]:
    queries = queries or []
    grouped: dict[str, dict[str, Any]] = {}
    files, skipped = _iter_files(home, days, max_file_mb)
    for path in files:
        for record in _extract_records(path):
            block = record["text"]
            if not _matches_query(block, path, queries):
                continue
            for hit in classify_block(block, role=record.get("role", "")):
                rule = hit["rule"]
                category = str(rule["category"])
                group = grouped.setdefault(
                    category,
                    {
                        "category": category,
                        "entity": rule["entity"],
                        "severity": rule["severity"],
                        "summary": rule["summary"],
                        "evidence": [],
                        "matched_patterns": set(),
                    },
                )
                group["matched_patterns"].update(hit["patterns"])
                if len(group["evidence"]) < limit:
                    group["evidence"].append(
                        {
                            "source_path": str(path),
                            "role": record.get("role", ""),
                            "snippet": _short(block, 700),
                        }
                    )
    candidates = []
    for category in sorted(grouped):
        group = grouped[category]
        evidence = group["evidence"]
        token_weight = len(_tokens(" ".join(item["snippet"] for item in evidence)))
        candidates.append(
            {
                "id": _stable_id([category, group["summary"]]),
                "category": category,
                "entity": group["entity"],
                "severity": group["severity"],
                "summary": group["summary"],
                "evidence": evidence,
                "matched_patterns": sorted(group["matched_patterns"]),
                "score": len(evidence) * 10 + token_weight,
            }
        )
    candidates.sort(key=lambda item: (-int(item["score"]), str(item["category"])))
    return {
        "schema": "legion.session-learning.scan.v1",
        "generated_at": _utc_now().isoformat().replace("+00:00", "Z"),
        "home": str(home),
        "lookback_days": days,
        "queries": queries,
        "files_scanned": len(files),
        "files_skipped": skipped,
        "max_file_mb": max_file_mb,
        "candidates": candidates,
    }


def _outcomes_path(log_root: str) -> Path:
    return Path(log_root).expanduser() / "self-learn" / "outcomes.jsonl"


def _outcome(candidate: dict[str, Any]) -> dict[str, Any]:
    target_type, target_name = str(candidate["entity"]).split(":", 1)
    evidence = "\n\n".join(
        (
            f"{item['source_path']} ({item['role']}): {item['snippet']}"
            if item.get("role")
            else f"{item['source_path']}: {item['snippet']}"
        )
        for item in candidate.get("evidence", [])
    )
    return {
        "schema": OUTCOME_SCHEMA,
        "id": _stable_id(["session-learn", candidate["category"], candidate["summary"]]),
        "ts": _utc_now().isoformat().replace("+00:00", "Z"),
        "source": "session-learn",
        "target_type": target_type,
        "target_name": target_name,
        "severity": candidate["severity"],
        "summary": _short(str(candidate["summary"]), 500),
        "evidence": _short(evidence, 1200),
        "run_id": "",
        "source_path": candidate["evidence"][0]["source_path"] if candidate.get("evidence") else "",
        "metadata": {
            "category": candidate["category"],
            "matched_patterns": candidate.get("matched_patterns", []),
        },
    }


def record_candidates(candidates: list[dict[str, Any]], log_root: str) -> list[dict[str, Any]]:
    outcomes = [_outcome(candidate) for candidate in candidates]
    path = _outcomes_path(log_root)
    path.parent.mkdir(parents=True, exist_ok=True)
    existing: set[str] = set()
    try:
        with path.open(encoding="utf-8") as handle:
            for line in handle:
                try:
                    payload = json.loads(line)
                except ValueError:
                    continue
                if isinstance(payload, dict) and payload.get("id"):
                    existing.add(str(payload["id"]))
    except OSError:
        pass
    new_outcomes = [outcome for outcome in outcomes if str(outcome.get("id")) not in existing]
    with path.open("a", encoding="utf-8") as handle:
        for outcome in new_outcomes:
            handle.write(json.dumps(outcome, sort_keys=True, ensure_ascii=False))
            handle.write("\n")
    return new_outcomes


def render(payload: dict[str, Any]) -> str:
    lines = [
        f"session-learn: {len(payload['candidates'])} candidate(s), "
        f"{payload['files_scanned']} files scanned, {payload.get('files_skipped', 0)} skipped"
    ]
    for candidate in payload["candidates"]:
        lines.append(f"\n{candidate['category']} -> {candidate['entity']} [{candidate['severity']}]")
        lines.append(f"- {candidate['summary']}")
        for evidence in candidate["evidence"][:2]:
            lines.append(f"  evidence: {evidence['source_path']}")
            lines.append(f"  {evidence['snippet']}")
    return "\n".join(lines)


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(prog="legion-session-learn")
    parser.add_argument("--home", default="~", help="home directory containing agent logs")
    parser.add_argument("--logs", default=DEFAULT_LOG_ROOT, help="Legion log root for --record")
    parser.add_argument("--lookback-days", type=int, default=3)
    parser.add_argument("--query", action="append", default=[], help="filter blocks by text")
    parser.add_argument("--limit", type=int, default=5, help="evidence snippets per category")
    parser.add_argument(
        "--max-file-mb",
        type=float,
        default=8.0,
        help="skip larger non-JSONL files; session JSONL is streamed regardless of size",
    )
    parser.add_argument("--record", action="store_true", help="append candidates as self-learning outcomes")
    parser.add_argument("--json", action="store_true")
    args = parser.parse_args(argv)
    if not args.logs:
        args.logs = legion_state.resolve_state(os.getcwd())["state_root"]

    payload = scan(
        Path(args.home).expanduser(),
        days=max(0, args.lookback_days),
        queries=list(args.query or []),
        limit=max(1, args.limit),
        max_file_mb=max(0.0, args.max_file_mb),
    )
    if args.record:
        payload["recorded"] = record_candidates(payload["candidates"], args.logs)
        payload["outcomes_path"] = str(_outcomes_path(args.logs))
    if args.json:
        print(json.dumps(payload, indent=2, sort_keys=True))
    else:
        print(render(payload))
        if args.record:
            print(f"\nrecorded: {len(payload['recorded'])} -> {payload['outcomes_path']}")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
