# Heldout OSS 36 Live Benchmark

Generated: 2026-06-27T09:56Z

This is the first live run of the packaged `heldout-oss-36` corpus after fixing
live adapter auth. The benchmark ran at commit `8fa18bb` on branch
`feat/legion-live-bench-v1`.

The first attempted live run was discarded because the bench runner isolated
`HOME`, so Codex, Claude, and Cursor could not read their normal credentials.
That exposed a real adapter bug. The fix exports `LEGION_BENCH_REAL_HOME` and
the live adapters restore `HOME` only for the CLI process, while keeping the
editable task workspace isolated.

## Command

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

## Results

| Mode | Pass | Case-runs | Pass rate | 95% CI | Cost | Tokens | Mean ms | P95 ms |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| `direct-codex` | 36 | 36 | `1.000` | `0.904-1.000` | `$0.000000` | 0 | 34442 | 47256 |
| `cursor-agent` | 36 | 36 | `1.000` | `0.904-1.000` | `$0.000000` | 0 | 25623 | 30166 |
| `legion-delegate` | 35 | 36 | `0.972` | `0.858-0.995` | `$3.226678` | 3372636 | 40418 | 70134 |
| `legion-cursor` | 35 | 36 | `0.972` | `0.858-0.995` | `$0.000000` | 0 | 25572 | 32368 |
| `direct-claude` | 0 | 36 | `0.000` | `0.000-0.096` | `$0.000000` | 0 | 4221 | 6144 |

`direct-claude` is not a valid Claude quality score from this run. Local Claude
Code `claude -p` returned `401 Invalid authentication credentials` even though
`claude auth status` reported a logged-in account, so every Claude case failed
before model work.

## Paired Comparisons

Baseline: `direct-codex`.

| Comparison | Delta pp | Relative | Candidate paired wins | Baseline paired wins | Both pass | McNemar p | Reliable |
|---|---:|---:|---:|---:|---:|---:|---|
| `direct-codex..cursor-agent` | `+0.000` | `+0.000%` | 0 | 0 | 36 | `n/a` | true |
| `direct-codex..legion-delegate` | `-2.778` | `-2.778%` | 0 | 1 | 35 | `1.000000` | true |
| `direct-codex..legion-cursor` | `-2.778` | `-2.778%` | 0 | 1 | 35 | `1.000000` | true |
| `direct-codex..direct-claude` | `-100.000` | `-100.000%` | 0 | 36 | 0 | `0.000000` | true |

The Legion wrapper gaps are not statistically significant on this sample
(`p=1.0`) but they are concrete failures to inspect.

## Failure Notes

- `legion-delegate` failed `py-parse-bool`: it left `return bool(value)`, so
  `"No"` and `"0"` evaluated to `True`.
- `legion-cursor` failed `py-tokenize-tags`: it left `return [text]`, so it did
  not split, lowercase, dedupe, and drop empty tags.
- `direct-claude` failed all cases due local CLI auth: `401 Invalid
  authentication credentials`.

## Interpretation

This benchmark measures `legion-core` harness paths, not `legion-code`
domain-specific skills. The current live result says:

- Direct Codex and direct Cursor Agent both solved the full held-out corpus.
- Legion's Codex and Cursor wrappers are now applying diffs correctly, but each
  lost one case versus direct mode.
- Claude needs machine auth fixed before a meaningful Claude number can be
  reported.
