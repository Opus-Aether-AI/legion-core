#!/usr/bin/env python3
"""Normalize Codex built-in review prose into Legion's typed verdict schema.

Codex may ignore ``--output-schema`` for ``codex exec review`` and emit its
stable human review format. This parser is intentionally narrow and fail-closed:
it accepts schema-valid JSON (after folding any extra per-finding fields into
that finding's ``detail``), recognized ``[P0]``–``[P3]`` findings, or an
explicit no-findings statement. Everything else remains invalid.
"""

from __future__ import annotations

import argparse
import json
import os
import re
import tempfile
from pathlib import Path
from typing import Any


FINDING = re.compile(
    r"^- \[P([0-3])\] (.+?) — (.+?):(\d+)(?:-\d+)?\s*$"
)
# An approval may only be inferred from an explicit statement that the review
# produced no findings, and only when that statement is the entire message.
# "looks good" is deliberately absent: it is a phrase a model emits
# conversationally, so accepting it let a reviewer that never really reviewed --
# or one steered by content inside the diff under review -- satisfy the gate
# that authorizes publishing a self-authored patch. The remaining phrases are
# assertions about the review outcome, not pleasantries.
APPROVAL = re.compile(
    r"^\s*(?:review summary:\s*)?"
    r"(?:no findings|no issues found|no issues|nothing to flag)"
    r"[.!]?\s*$",
    re.IGNORECASE,
)
SEVERITY = {"0": "critical", "1": "high", "2": "medium", "3": "low"}
MAX_INPUT_BYTES = 1_048_576


def _valid(payload: Any) -> bool:
    if not isinstance(payload, dict) or set(payload) != {
        "verdict",
        "summary",
        "findings",
    }:
        return False
    if payload.get("verdict") not in {"approve", "request_changes", "comment"}:
        return False
    if not isinstance(payload.get("summary"), str) or not isinstance(
        payload.get("findings"), list
    ):
        return False
    allowed = {"severity", "title", "file", "line", "detail"}
    for finding in payload["findings"]:
        if (
            not isinstance(finding, dict)
            or set(finding) - allowed
            or finding.get("severity") not in set(SEVERITY.values())
            or not isinstance(finding.get("title"), str)
            or not finding["title"]
        ):
            return False
        if "file" in finding and not isinstance(finding["file"], str):
            return False
        if "line" in finding and (
            not isinstance(finding["line"], int)
            or isinstance(finding["line"], bool)
            or finding["line"] < 1
        ):
            return False
        if "detail" in finding and not isinstance(finding["detail"], str):
            return False
    if payload["verdict"] in {"approve", "comment"} and any(
        finding.get("severity") in {"critical", "high", "medium"}
        for finding in payload["findings"]
    ):
        return False
    return True


FINDING_KEYS = ("severity", "title", "file", "line", "detail")
MAX_DETAIL = 4000


def _fold_extra_finding_fields(payload: Any) -> Any:
    """Fold fields a reviewer added to a finding into that finding's ``detail``.

    Prompt reviewers often attach a helpful extra field to a finding (a quote, a
    failure scenario, a suggested fix). The schema has no place for it, so the
    whole verdict used to be rejected and a run failed on format rather than
    substance. Folding keeps the information, and is deliberately the only
    repair: the verdict, the summary, every severity and title are left exactly
    as written, so a fold can never turn a finding into an approval, and
    anything else malformed still fails closed in ``_valid``.
    """
    if not isinstance(payload, dict) or not isinstance(payload.get("findings"), list):
        return payload
    folded = []
    for finding in payload["findings"]:
        if not isinstance(finding, dict):
            return payload
        extra = sorted(set(finding) - set(FINDING_KEYS))
        if not extra:
            folded.append(finding)
            continue
        kept = {key: finding[key] for key in FINDING_KEYS if key in finding}
        if "detail" in kept and not isinstance(kept["detail"], str):
            return payload
        # the reviewer's own detail is kept whole; only the folded fields are capped
        added = "\n".join(
            f"{key}: {finding[key] if isinstance(finding[key], str) else json.dumps(finding[key], sort_keys=True)}"
            for key in extra
        )[:MAX_DETAIL]
        original = kept.get("detail", "")
        kept["detail"] = f"{original}\n{added}" if original else added
        folded.append(kept)
    return dict(payload, findings=folded)


def _json_payload(text: str) -> dict[str, Any] | None:
    stripped = text.strip()
    if stripped.startswith("```") and stripped.endswith("```"):
        lines = stripped.splitlines()
        stripped = "\n".join(lines[1:-1]).strip()
    try:
        payload = json.loads(stripped)
    except (TypeError, ValueError):
        return None
    if _valid(payload):
        return payload
    folded = _fold_extra_finding_fields(payload)
    return folded if _valid(folded) else None


def _safe_file(value: str, repo: Path) -> str:
    try:
        return str(Path(value).resolve().relative_to(repo.resolve()))
    except (OSError, ValueError):
        return value[:500]


def normalize(text: str, repo: Path) -> dict[str, Any] | None:
    payload = _json_payload(text)
    if payload is not None:
        return payload
    lines = text.splitlines()
    findings: list[dict[str, Any]] = []
    current: dict[str, Any] | None = None
    summary_lines: list[str] = []
    in_comments = False
    for line in lines:
        if line.strip().lower() == "full review comments:":
            in_comments = True
            continue
        match = FINDING.match(line)
        if match:
            if current is not None:
                findings.append(current)
            priority, title, filename, line_number = match.groups()
            current = {
                "severity": SEVERITY[priority],
                "title": title.strip()[:500],
                "file": _safe_file(filename.strip(), repo),
                "line": int(line_number),
                "detail": "",
            }
            in_comments = True
        elif current is not None and line.strip():
            current["detail"] = (current["detail"] + " " + line.strip()).strip()[:4000]
        elif not in_comments and line.strip():
            summary_lines.append(line.strip())
    if current is not None:
        findings.append(current)
    for finding in findings:
        if not finding.get("detail"):
            finding.pop("detail", None)
    summary = " ".join(summary_lines).strip()[:2000]
    if findings:
        return {
            "verdict": "request_changes",
            "summary": summary or f"Review found {len(findings)} actionable issue(s).",
            "findings": findings,
        }
    # Never turn an unfamiliar priority-bearing format into an approval. Codex's
    # recognized finding format is intentionally the only lossy conversion.
    if re.search(r"\[P[0-3]\]", text, re.I):
        return None
    if APPROVAL.search(text):
        return {
            "verdict": "approve",
            "summary": summary or "No findings.",
            "findings": [],
        }
    return None


def atomic_write(path: Path, payload: dict[str, Any]) -> None:
    descriptor, temporary = tempfile.mkstemp(prefix=".review-verdict-", dir=path.parent)
    try:
        with os.fdopen(descriptor, "w", encoding="utf-8") as handle:
            json.dump(payload, handle, sort_keys=True, separators=(",", ":"))
            handle.write("\n")
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(temporary, path)
    finally:
        try:
            os.unlink(temporary)
        except FileNotFoundError:
            pass


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("verdict")
    parser.add_argument("--repo", required=True)
    args = parser.parse_args()
    path = Path(args.verdict)
    try:
        if path.stat().st_size > MAX_INPUT_BYTES:
            return 1
        text = path.read_text(encoding="utf-8")
    except OSError:
        return 1
    payload = normalize(text, Path(args.repo))
    if payload is None:
        return 1
    atomic_write(path, payload)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
