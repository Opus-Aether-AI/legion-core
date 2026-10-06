#!/usr/bin/env python3
"""legion-doc-check: deterministic gates for document work (docs/document-workflows.md).

Checks the files a document workflow publishes, and the records around them, for the failures
that reviews keep finding by hand:

  markers       an outward file still carries [PROOF NEEDED: ...], [DETAIL NEEDED: ...], TODO, TBD or FIXME
  tokens        an outward file still shows an unresolved template token ({=key}, {{key}})
  deny          an outward file matches a confidentiality deny pattern from the config
  supersession  a record whose opening lines say it is superseded does not name what superseded it

Outward files (--publish) and records (--records) are globs relative to --repo. Markdown, text,
HTML and JSON are read as text; PDFs are read through `pdftotext` when it is installed. Nothing
is ever silently treated as clean: a file that cannot be read (no pdftotext, a PDF with no text
layer, an unsupported type) and a glob that matches no files (unless --allow-empty) are listed
under `unchecked` and fail the report. Prints one JSON report with `ok`, per-check counts,
findings, `unchecked` and `learning_feedback`, so it can sit inside a legion-run
--validate-command. Exits 1 when a blocking check has findings or anything went unchecked, 2 on
a usage or configuration error.

Configuration may also come from a JSON or TOML file (--config) with the same keys:
publish, records, markers, tokens (lists of strings), deny ([{category, pattern}]), advisory
(checks that report but never fail), superseded_pattern, successor_pattern, head_lines,
successor_window (how many lines after a "superseded" line may name the successor) and
allow_empty. Every value is type-checked and every pattern compiled before anything is read.
"""

from __future__ import annotations

import argparse
import glob
import json
import os
import re
import shutil
import subprocess
import sys
from pathlib import Path
from typing import Any

try:  # Python 3.11+
    import tomllib
except ModuleNotFoundError:  # pragma: no cover - older interpreters read JSON configs only
    tomllib = None

CHECKS = ("markers", "tokens", "deny", "supersession")
DEFAULTS: dict[str, Any] = {
    "publish": [],
    "records": [],
    "markers": [r"\[(?:PROOF|DETAIL|SOURCE|CITATION) NEEDED[^\]]*\]", r"\bTODO\b", r"\bTBD\b", r"\bFIXME\b"],
    "tokens": [r"\{=[^}\s]+\}", r"\{\{\s*[^}]+\}\}"],
    "deny": [],
    "advisory": [],
    "superseded_pattern": r"(?i)\bsuperseded\b",
    "successor_pattern": r"\]\([^)]+\)|`[^`\s]+\.[A-Za-z0-9]{1,5}`|`[^`\s]+/[^`\s]*`",
    "head_lines": 15,
    "successor_window": 2,
    "allow_empty": False,
}
LIST_KEYS = ("publish", "records", "markers", "tokens", "advisory")
TEXT_SUFFIXES = {".md", ".markdown", ".txt", ".html", ".htm", ".json", ".csv", ".tex", ".rst"}
MAX_MATCH = 160


def load_config(path: str | None) -> dict[str, Any]:
    config = dict(DEFAULTS)
    if not path:
        return config
    raw = Path(path).read_bytes()
    if path.endswith(".toml"):
        if tomllib is None:
            raise ValueError("TOML configs need Python 3.11+; use JSON")
        loaded = tomllib.loads(raw.decode("utf-8"))
    else:
        loaded = json.loads(raw.decode("utf-8"))
    if not isinstance(loaded, dict):
        raise ValueError("the config must be a table of keys")
    unknown = set(loaded) - set(DEFAULTS)
    if unknown:  # a misspelled key is an error, not a silently skipped check
        raise ValueError(f"unknown config key(s): {', '.join(sorted(unknown))}")
    config.update(loaded)
    return config


def validate_config(config: dict[str, Any], require_targets: bool = True) -> None:
    """Reject a config that would check less than it says; every error is a usage error (exit 2)."""
    for key in LIST_KEYS:
        value = config[key]
        if not isinstance(value, list) or not all(isinstance(item, str) for item in value):
            raise ValueError(f"{key} must be a list of strings")  # a bare string would be globbed letter by letter
    unknown = set(config["advisory"]) - set(CHECKS)
    if unknown:
        raise ValueError(f"advisory names unknown check(s): {', '.join(sorted(unknown))}")
    deny = config["deny"]
    if not isinstance(deny, list) or not all(
            isinstance(item, dict) and set(item) <= {"category", "pattern"} and isinstance(item.get("pattern"), str)
            and isinstance(item.get("category", "deny"), str) and item.get("category", "deny") for item in deny):
        raise ValueError("deny must be a list of {category, pattern} tables with a non-empty category")
    for key in ("superseded_pattern", "successor_pattern"):
        if not isinstance(config[key], str):
            raise ValueError(f"{key} must be a string")
    for key, least in (("head_lines", 1), ("successor_window", 0)):
        value = config[key]
        if isinstance(value, bool) or not isinstance(value, int) or value < least:
            raise ValueError(f"{key} must be an integer of at least {least}")
    if not isinstance(config["allow_empty"], bool):
        raise ValueError("allow_empty must be true or false")
    patterns = config["markers"] + config["tokens"] + [item["pattern"] for item in deny]
    for pattern in patterns + [config["superseded_pattern"], config["successor_pattern"]]:
        try:
            re.compile(pattern)
        except re.error as error:
            raise ValueError(f"invalid pattern {pattern!r}: {error}") from error
    if require_targets and not config["publish"] and not config["records"]:
        raise ValueError("nothing to check: give --publish and/or --records (or a config)")
    if require_targets and config["publish"] and not (config["markers"] or config["tokens"] or deny):
        raise ValueError("--publish needs at least one check: markers, tokens or deny are all empty")


def expand(repo: Path, patterns: list[str]) -> tuple[list[Path], list[str]]:
    """The files the globs match, and the globs that matched nothing."""
    files: set[Path] = set()
    empty: list[str] = []
    for pattern in patterns:
        matched = [Path(m) for m in glob.glob(str(repo / pattern), recursive=True) if Path(m).is_file()]
        if not matched:
            empty.append(pattern)
        files.update(matched)
    return sorted(files), empty


def read_text(path: Path) -> tuple[str | None, str | None]:
    """The file's text, or (None, reason) when it cannot be read as text."""
    suffix = path.suffix.lower()
    if suffix == ".pdf":
        if not shutil.which("pdftotext"):
            return None, "pdftotext is not installed, so this PDF was not checked"
        done = subprocess.run(["pdftotext", "-layout", str(path), "-"], capture_output=True, text=True, check=False)
        if done.returncode != 0:
            return None, f"pdftotext failed: {done.stderr.strip()[:200]}"
        if not done.stdout.strip() and path.stat().st_size > 0:
            return None, "pdftotext found no text (a scanned or outlined PDF), so this PDF was not checked"
        return done.stdout, None
    if suffix in TEXT_SUFFIXES or not suffix:
        try:
            return path.read_text(encoding="utf-8", errors="replace"), None
        except OSError as error:
            return None, f"cannot read: {error.strerror or error}"
    return None, f"unsupported file type {suffix}"


def scan(text: str, patterns: list[tuple[str, str]]) -> list[tuple[int, str, str]]:
    """(line, label, match) for every pattern hit; label is the pattern's category or the pattern."""
    hits = []
    compiled = [(label, re.compile(pattern)) for label, pattern in patterns]
    for number, line in enumerate(text.splitlines(), 1):
        for label, regex in compiled:
            for match in regex.finditer(line):
                hits.append((number, label, match.group(0)[:MAX_MATCH]))
    return hits


def check(repo: Path, config: dict[str, Any]) -> dict[str, Any]:
    findings: list[dict[str, Any]] = []
    notes: list[str] = []
    counts = {name: {"files": 0, "findings": 0} for name in CHECKS}
    publish, empty_publish = expand(repo, config["publish"])
    records, empty_records = expand(repo, config["records"])
    empty = [f"--publish {p!r}" for p in empty_publish] + [f"--records {p!r}" for p in empty_records]
    if not config["allow_empty"]:
        notes.extend(f"{glob_}: matched no files, so nothing was checked for it" for glob_ in empty)

    def add(name: str, path: Path, line: int, label: str, match: str) -> None:
        counts[name]["findings"] += 1
        findings.append({"check": name, "blocking": name not in config["advisory"],
                         "file": os.path.relpath(path, repo), "line": line, "pattern": label, "match": match})

    groups = {
        "markers": [(p, p) for p in config["markers"]],
        "tokens": [(p, p) for p in config["tokens"]],
        "deny": [(d.get("category", "deny"), d["pattern"]) for d in config["deny"]],
    }
    for path in publish:
        text, reason = read_text(path)
        if text is None:
            notes.append(f"{os.path.relpath(path, repo)}: {reason}")
            continue
        for name, patterns in groups.items():
            if not patterns:
                continue
            counts[name]["files"] += 1
            for line, label, match in scan(text, patterns):
                add(name, path, line, label, match)

    superseded = re.compile(config["superseded_pattern"])
    successor = re.compile(config["successor_pattern"])
    for path in records:
        text, reason = read_text(path)
        if text is None:
            notes.append(f"{os.path.relpath(path, repo)}: {reason}")
            continue
        counts["supersession"]["files"] += 1
        head = text.splitlines()[: int(config["head_lines"])]
        marked = [index for index, line in enumerate(head) if superseded.search(line)]
        window = int(config["successor_window"])
        # the successor must be named on the "superseded" line or just after it, not anywhere in the header
        if marked and not any(successor.search(line) for index in marked for line in head[index:index + window + 1]):
            add("supersession", path, marked[0] + 1, "superseded without a successor", head[marked[0]].strip()[:MAX_MATCH])

    blocking = [f for f in findings if f["blocking"]]
    feedback = [{
        "id": f"doc-check-{name}",
        "source": "validation-feedback",
        "target_type": "heavy-task",
        "target_name": config.get("name", "documents"),
        "severity": "high" if name not in config["advisory"] else "low",
        "summary": f"{counts[name]['findings']} {name} finding(s) in checked documents",
        "evidence": {"validator": "legion-doc-check", "passed": False,
                     "examples": [f"{f['file']}:{f['line']}: {f['match']}" for f in findings if f["check"] == name][:5]},
    } for name in CHECKS if counts[name]["findings"]]
    if notes:
        feedback.append({
            "id": "doc-check-unchecked", "source": "validation-feedback", "target_type": "heavy-task",
            "target_name": config.get("name", "documents"), "severity": "high",
            "summary": f"{len(notes)} file(s) or glob(s) could not be checked",
            "evidence": {"validator": "legion-doc-check", "passed": False, "examples": notes[:5]},
        })
    return {"ok": not blocking and not notes, "checks": counts, "findings": findings,
            "unchecked": notes, "empty_globs": empty, "learning_feedback": feedback}


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(prog="legion-doc-check", description=__doc__.split("\n\n")[0])
    parser.add_argument("--repo", default=".", help="repository root the globs are relative to")
    parser.add_argument("--config", help="JSON or TOML file with the same keys as the flags")
    parser.add_argument("--publish", action="append", default=None, help="glob of outward-bound files (repeatable)")
    parser.add_argument("--records", action="append", default=None, help="glob of records to check for supersession")
    parser.add_argument("--deny", action="append", default=None, metavar="CATEGORY=REGEX",
                        help="a confidentiality deny pattern (repeatable)")
    parser.add_argument("--advisory", action="append", default=None, choices=CHECKS, help="report but do not fail")
    parser.add_argument("--allow-empty", action="store_true", help="a glob that matches no files is not an error")
    parser.add_argument("--name", default="documents", help="the run or document set, for learning feedback")
    parser.add_argument("--json", action="store_true", help="print the JSON report (default)")
    args = parser.parse_args(argv)
    try:
        config = load_config(args.config)
        validate_config(config, require_targets=False)   # before the flags are merged in
        if args.publish:
            config["publish"] = config["publish"] + args.publish
        if args.records:
            config["records"] = config["records"] + args.records
        if args.advisory:
            config["advisory"] = config["advisory"] + args.advisory
        for item in args.deny or []:
            category, _, pattern = item.partition("=")
            if not pattern:
                raise ValueError(f"--deny needs CATEGORY=REGEX, got {item!r}")
            config["deny"] = config["deny"] + [{"category": category, "pattern": pattern}]
        if args.allow_empty:
            config["allow_empty"] = True
        validate_config(config)
        config["name"] = args.name
    except (OSError, ValueError, KeyError, TypeError, re.error) as error:
        print(json.dumps({"ok": False, "error": str(error)}), file=sys.stderr)
        return 2
    report = check(Path(args.repo).resolve(), config)
    print(json.dumps(report, indent=2, sort_keys=True))
    return 0 if report["ok"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
