# Heldout OSS 36 Control Benchmark

Generated: 2026-06-26T22:50Z

This is the no-spend control run for the packaged `heldout-oss-36` corpus. It
proves the 36-case corpus, command validators, paired statistics, failure
clustering, reliability gate, and Markdown report path.

It is not a live model-quality claim. Live direct-Codex versus Legion numbers
come from selecting live modes explicitly.

## Result

| Mode | Pass | Case-runs | Pass rate | 95% CI | Cost | Tokens |
|---|---:|---:|---:|---:|---:|---:|
| `scripted-baseline` | 0 | 36 | `0.000` | `0.000-0.096` | `$0.000000` | 0 |
| `scripted-oracle` | 36 | 36 | `1.000` | `0.904-1.000` | `$0.000000` | 0 |

Comparison:

- absolute delta: `+100.000` percentage points
- paired case-runs: `36`
- candidate paired wins: `36`
- baseline paired wins: `0`
- McNemar exact p-value: `< 0.000001`
- reliable: `true` because `36 >= 30`

## Reproduce

```bash
LEGION_BENCH_DIR=/tmp/legion-heldout-run/bench \
LEGION_TELEMETRY_DIR=/tmp/legion-heldout-run/spans \
  legion-observability/bin/legion-bench corpus \
  --corpus heldout-oss-36 \
  --repo . \
  --json \
  --strict \
  --require-reliable \
  --report-md /tmp/legion-heldout-run/report.md
```

Live Codex versus Legion run:

```bash
legion-observability/bin/legion-bench corpus \
  --corpus heldout-oss-36 \
  --repo . \
  --mode direct-codex \
  --mode legion-delegate \
  --baseline direct-codex \
  --require-reliable \
  --report-md /tmp/direct-codex-vs-legion.md \
  --json
```
