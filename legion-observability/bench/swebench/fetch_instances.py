#!/usr/bin/env python3
"""Fetch SWE-bench Lite instances into a local manifest (stdlib only).

SWE-bench (https://github.com/swe-bench/SWE-bench) is the repository-level
external benchmark: each instance is a real GitHub issue + repo @ base_commit,
with a gold `patch`, a `test_patch`, and FAIL_TO_PASS / PASS_TO_PASS test ids.
Unlike the file-overlay corpora, SWE-bench needs a repo checkout and a per-repo
environment, so it is wired as a separate adapter rather than a
legion.bench.corpus.v1 corpus.

This fetcher pulls instances from the HuggingFace datasets-server API (no
`datasets` install) and writes a manifest JSON the adapter scripts consume.

  python3 fetch_instances.py --out manifest.json --limit 5
  python3 fetch_instances.py --out manifest.json --repo pallets/flask
  python3 fetch_instances.py --out manifest.json --instance pallets__flask-4045
"""
from __future__ import annotations

import argparse
import json
import sys
import urllib.request

DATASET = "princeton-nlp/SWE-bench_Lite"
API = "https://datasets-server.huggingface.co/rows"
KEYS = (
    "instance_id", "repo", "base_commit", "environment_setup_commit",
    "version", "problem_statement", "patch", "test_patch",
    "FAIL_TO_PASS", "PASS_TO_PASS",
)


def _page(offset: int, length: int = 100) -> list[dict]:
    url = f"{API}?dataset={DATASET.replace('/', '%2F')}&config=default&split=test&offset={offset}&length={length}"
    with urllib.request.urlopen(url, timeout=30) as handle:
        return [row["row"] for row in json.load(handle)["rows"]]


def iter_instances():
    offset = 0
    while True:
        rows = _page(offset)
        if not rows:
            return
        yield from rows
        offset += len(rows)
        if len(rows) < 100:
            return


def main() -> int:
    ap = argparse.ArgumentParser(description="Fetch SWE-bench Lite instances → manifest")
    ap.add_argument("--out", required=True)
    ap.add_argument("--limit", type=int, default=0, help="max instances (0 = all)")
    ap.add_argument("--repo", default="", help="only this repo (e.g. pallets/flask)")
    ap.add_argument("--instance", default="", help="only this instance_id")
    args = ap.parse_args()

    out: list[dict] = []
    for row in iter_instances():
        if args.instance and row["instance_id"] != args.instance:
            continue
        if args.repo and row["repo"] != args.repo:
            continue
        out.append({k: row.get(k) for k in KEYS})
        if args.limit and len(out) >= args.limit:
            break

    if not out:
        print(
            "error: no instances matched (check --repo / --instance, or the dataset is unreachable); "
            "refusing to write an empty manifest",
            file=sys.stderr,
        )
        return 1
    manifest = {"schema": "legion.swebench.manifest.v1", "dataset": DATASET, "instances": out}
    with open(args.out, "w", encoding="utf-8") as handle:
        json.dump(manifest, handle, indent=2)
        handle.write("\n")
    print(f"wrote {len(out)} instance(s) to {args.out}", file=sys.stderr)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
