# Heldout OSS 36 Live Benchmark

Generated: 2026-06-27T09:56Z
Updated: 2026-06-27T10:29Z with corrected Claude run

This is the first live run of the packaged `heldout-oss-36` corpus after fixing
live adapter auth. The benchmark ran at commit `8fa18bb` on branch
`feat/legion-live-bench-v1`.

The first attempted live run was discarded because the bench runner isolated
`HOME`, so Codex, Claude, and Cursor could not read their normal credentials.
That exposed a real adapter bug. The fix exports `LEGION_BENCH_REAL_HOME` and
the live adapters restore `HOME` only for the CLI process, while keeping the
editable task workspace isolated.

Claude auth was still broken on the first corrected full-matrix run. After
`claude -p` was fixed, `direct-claude` was rerun separately against the same
36-case corpus at commit `34f1bdb`.

## Command

Full matrix:

```bash
LEGION_BENCH_DIR=/tmp/legion-live-full-fixed-20260627T083837Z/bench \
LEGION_TELEMETRY_DIR=/tmp/legion-live-full-fixed-20260627T083837Z/spans \
  legion-observability/bin/legion-bench corpus \
  --corpus heldout-oss-36 \
  --repo . \
  --mode direct-codex \
  --mode legion-delegate \
  --mode direct-claude \
  --mode cursor-agent \
  --mode legion-cursor \
  --baseline direct-codex \
  --require-reliable \
  --json \
  --report-md /tmp/legion-live-full-fixed-20260627T083837Z/live-full-fixed-report.md
```

Claude rerun:

```bash
LEGION_BENCH_DIR=/tmp/legion-live-claude-fixed-20260627T101509Z/bench \
LEGION_TELEMETRY_DIR=/tmp/legion-live-claude-fixed-20260627T101509Z/spans \
  legion-observability/bin/legion-bench corpus \
  --corpus heldout-oss-36 \
  --repo . \
  --mode direct-claude \
  --baseline direct-claude \
  --require-reliable \
  --json \
  --report-md /tmp/legion-live-claude-fixed-20260627T101509Z/direct-claude-report.md
```

## Results

| Mode | Pass | Case-runs | Pass rate | 95% CI | Cost | Tokens | Mean ms | P95 ms |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| `direct-codex` | 36 | 36 | `1.000` | `0.904-1.000` | `$0.000000` | 0 | 34442 | 47256 |
| `cursor-agent` | 36 | 36 | `1.000` | `0.904-1.000` | `$0.000000` | 0 | 25623 | 30166 |
| `direct-claude` | 36 | 36 | `1.000` | `0.904-1.000` | `$0.000000` | 0 | 24073 | 29865 |
| `legion-delegate` | 35 | 36 | `0.972` | `0.858-0.995` | `$3.226678` | 3372636 | 40418 | 70134 |
| `legion-cursor` | 35 | 36 | `0.972` | `0.858-0.995` | `$0.000000` | 0 | 25572 | 32368 |

Cost/tokens for direct harness adapters remain `0` in this report because those
modes do not emit `legion.span.v1` records yet. `legion-delegate` and
`legion-cursor` do emit spans, so their span counts and delegated cost can be
reported.

## Paired Comparisons

Baseline: `direct-codex`.

| Comparison | Delta pp | Relative | Candidate paired wins | Baseline paired wins | Both pass | McNemar p | Reliable |
|---|---:|---:|---:|---:|---:|---:|---|
| `direct-codex..cursor-agent` | `+0.000` | `+0.000%` | 0 | 0 | 36 | `n/a` | true |
| `direct-codex..legion-delegate` | `-2.778` | `-2.778%` | 0 | 1 | 35 | `1.000000` | true |
| `direct-codex..legion-cursor` | `-2.778` | `-2.778%` | 0 | 1 | 35 | `1.000000` | true |

The corrected Claude run was separate from the full matrix, so it does not have
a same-run paired McNemar comparison against direct Codex. Its headline pass
rate is equal: `36/36`.

The Legion wrapper gaps are not statistically significant on this sample
(`p=1.0`) but they are concrete failures to inspect.

## Failure Notes

- `legion-delegate` failed `py-parse-bool`: it left `return bool(value)`, so
  `"No"` and `"0"` evaluated to `True`.
- `legion-cursor` failed `py-tokenize-tags`: it left `return [text]`, so it did
  not split, lowercase, dedupe, and drop empty tags.

## Interpretation

This benchmark measures `legion-core` harness paths, not `legion-code`
domain-specific skills. The current live result says:

- Direct Codex, direct Claude, and direct Cursor Agent solved the full held-out
  corpus.
- Legion's Codex and Cursor wrappers are now applying diffs correctly, but each
  lost one case versus direct mode.
