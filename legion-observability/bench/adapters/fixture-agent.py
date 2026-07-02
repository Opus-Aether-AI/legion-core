#!/usr/bin/env python3
"""Deterministic corpus adapter used for no-spend benchmark controls."""

from __future__ import annotations

import argparse
import json
import os
from pathlib import Path
from typing import Any


def _write_files(root: Path, files: dict[str, Any]) -> None:
    for rel, content in files.items():
        path = root / rel
        path.parent.mkdir(parents=True, exist_ok=True)
        if isinstance(content, (dict, list)):
            path.write_text(json.dumps(content, indent=2, sort_keys=True) + "\n", encoding="utf-8")
        else:
            path.write_text(str(content), encoding="utf-8")


def main() -> int:
    parser = argparse.ArgumentParser(prog="fixture-agent")
    parser.add_argument("--case", default=os.environ.get("LEGION_BENCH_CASE_FILE", "case.json"))
    parser.add_argument("--workspace", default=os.environ.get("LEGION_BENCH_WORKSPACE", "."))
    parser.add_argument("--apply", choices=["none", "baseline", "answer"], default="none")
    args = parser.parse_args()

    case_path = Path(args.case)
    workspace = Path(args.workspace)
    payload = json.loads(case_path.read_text(encoding="utf-8"))
    if args.apply == "baseline":
        _write_files(workspace, payload.get("baseline_files") or {})
    elif args.apply == "answer":
        _write_files(workspace, payload.get("answer_files") or {})
    print(json.dumps({
        "schema": "legion.bench.fixture-agent.v1",
        "case": payload.get("id"),
        "apply": args.apply,
    }, sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
