# PR #47 Real Benchmark Results

Generated: 2026-06-26T22:02Z

This run compares the current PR benchmark suite against the current
`origin/main` checkout, not a hand-picked fixture. The same 49-case `stable`
suite was run against both repos through `legion-bench run`, then compared with
`legion-bench compare`.

The candidate commit below is the benchmark-affecting code commit. Later
docs-only commits in this PR do not change the suite, runner, or measured
behavior.

## Result

| Metric | `origin/main` | PR candidate | Delta |
|---|---:|---:|---:|
| Benchmark-affecting commit | `3ce4eee` | `2e3bba9` | |
| Score | `0.877551` | `1.000000` | `+12.245` pp |
| Relative score lift | | | `+13.953%` |
| Passes | `43/49` | `49/49` | `+6` |
| Failures | `6` | `0` | `-6` |
| `cli-contract` pass rate | `2/8` | `8/8` | `+75.000` pp |
| Task pass rate | `5/11` | `11/11` | `+54.546` pp |

`legion-bench compare` reported `status: improved` with no quality regressions.

The six baseline failures are the new PR feature contracts:

- `task.bench-corpus-cli`
- `task.bench-corpus-packaged`
- `task.intake-cli-generic-worker-help`
- `task.package-bin-legion-intake`
- `task.router-plugin-intake-metadata`
- `task.marketplace-intake-metadata`

## Reproduction

```bash
git fetch origin main
git worktree add --detach /tmp/legion-core-origin-main-bench origin/main

OUT=/tmp/legion-pr47-real-bench-2e3bba9
SUITE="$PWD/legion-observability/bench/stable.json"

LEGION_BENCH_DIR="$OUT/baseline" \
LEGION_TELEMETRY_DIR="$OUT/baseline/spans" \
  legion-observability/bin/legion-bench run \
  --repo /tmp/legion-core-origin-main-bench \
  --suite "$SUITE" \
  --json --quiet > "$OUT/baseline-stable.json"

LEGION_BENCH_DIR="$OUT/candidate" \
LEGION_TELEMETRY_DIR="$OUT/candidate/spans" \
  legion-observability/bin/legion-bench run \
  --repo "$PWD" \
  --suite "$SUITE" \
  --json --quiet > "$OUT/candidate-stable.json"

legion-observability/bin/legion-bench compare \
  --baseline "$(jq -r '.summary_path' "$OUT/baseline-stable.json")" \
  --candidate "$(jq -r '.summary_path' "$OUT/candidate-stable.json")" \
  --json > "$OUT/compare.json"
```

Artifacts from the run:

- `/tmp/legion-pr47-real-bench-2e3bba9/baseline/runs/20260626T220252Z-stable-34dacf87/summary.json`
- `/tmp/legion-pr47-real-bench-2e3bba9/candidate/runs/20260626T220253Z-stable-d890b85e/summary.json`
- `/tmp/legion-pr47-real-bench-2e3bba9/compare.json`

## Scope

This is a real PR-vs-main feature-contract benchmark. It runs the actual
Legion CLIs and metadata checks that this PR adds, using the branch suite
against both the base and candidate repos.

It is not yet the larger live LLM benchmark comparing direct Codex, direct
Claude Code, Cursor, and Legion orchestration on a 30+ case corpus. That is the
next benchmark layer now that the deterministic scorecard and corpus runner are
in place.
