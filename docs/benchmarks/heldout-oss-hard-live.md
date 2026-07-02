# Heldout OSS Hard — Live Benchmark (discriminating tier)

Generated: 2026-06-27. Single commit, single run. Bench root under a short `/tmp`
path so the cursor modes trust their workspace (see Reliability findings).

`heldout-oss-hard` is the discriminating tier: 19 held-out pure-Python tasks that
are multi-file (`account.py`+`bank.py`, `rules.py`+`form.py`, `steps.py`+`pipeline.py`),
longer-horizon (INI/CSV/glob parsers, RPN eval, topological sort, turnstile FSM,
spiral read), constrained bug-fixes (median, paginator), or rich multi-assertion
edge cases (roman numerals). It exists because `heldout-oss-36` is saturated and
cannot tell two harnesses apart.

## Command

```bash
LEGION_BENCH_DIR=/tmp/lm-XXXX/bench LEGION_TELEMETRY_DIR=/tmp/lm-XXXX/spans \
legion-observability/bin/legion-bench corpus --corpus heldout-oss-hard --repo . \
  --mode direct-codex --mode direct-claude --mode cursor-agent \
  --mode legion-delegate --mode legion-cursor \
  --baseline direct-codex --repeat 2 --record-failures \
  --report-md /tmp/lm-XXXX/heldout-oss-hard-live.md --json
```

5 modes × 19 cases × repeat 2 = 38 case-runs per mode.

## Results

| Mode | Pass | Case-runs | Pass rate | 95% CI | Cost | Tokens | Mean ms | P95 ms |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| `cursor-agent` | 38 | 38 | 1.000 | 0.908-1.000 | `$0.000000` (unmetered) | 3996674 | 26793 | 32745 |
| `direct-claude` | 38 | 38 | 1.000 | 0.908-1.000 | `$14.833153` | 6793154 | 28641 | 40615 |
| `direct-codex` | 38 | 38 | 1.000 | 0.908-1.000 | `$3.785857` | 3347629 | 34954 | 55176 |
| `legion-cursor` | 38 | 38 | 1.000 | 0.908-1.000 | `$0.000000` (unmetered) | 3939280 | 27052 | 31957 |
| `legion-delegate` | 38 | 38 | 1.000 | 0.908-1.000 | `$3.953395` | 3698718 | 43278 | 86763 |

Baseline `direct-codex`:

| Comparison | Delta pp | McNemar p | Cost delta | Duration delta ms |
|---|---:|---:|---:|---:|
| `direct-codex..cursor-agent` | +0.000 | n/a | `$-3.785857` | -310138 |
| `direct-codex..direct-claude` | +0.000 | n/a | `$+11.047296` | -239898 |
| `direct-codex..legion-cursor` | +0.000 | n/a | `$-3.785857` | -300300 |
| `direct-codex..legion-delegate` | +0.000 | n/a | `$+0.167538` | +316304 |

## Interpretation — the signal is cost, not pass rate

Every mode scored **38/38**. Even this harder tier is **correctness-saturated** for
frontier single-shot models on self-contained Python — pass rate does not
discriminate. What *does* separate the modes, now that the direct adapters emit real
`legion.span.v1` spans, is **cost at equal quality**:

- **Legion's historical cost-routing thesis became measurable in this run.** `legion-delegate`
  reaches the same 38/38 as `direct-claude` for **$3.95 vs $14.83 — about 1/4 the
  cost** ($10.88 saved), because the then-current router sent the work to
  `gpt-5.4` (via Codex) instead of a premium Claude model. Current runs use
  `gpt-5.5` for Legion-managed Codex work; this is the headline number the
  benchmark previously could not produce, because direct adapters reported `$0`.
- **The Legion wrapper adds negligible cost over the raw executor it routes to.**
  `legion-delegate` ($3.95) vs `direct-codex` ($3.79) is a `+$0.17` delta — the
  orchestration/telemetry/worktree overhead is real but small. It does add latency
  (mean 43.3s vs 35.0s; P95 86.8s vs 55.2s) from the isolated-worktree + verify loop.
- **Cursor is unmetered.** `cursor-agent` / `legion-cursor` run on a Cursor
  subscription with no per-call USD price, so cost is `$0` by design (not a missing
  measurement). Token volume is still reported for work-volume parity.

Honest caveat: because frontier models one-shot these tasks, the hard tier currently
discriminates on **cost and latency**, not correctness. A future tier that pushes past
single-shot capability (repository-scale tasks, ambiguous specs, or a tighter step
budget) is what would move pass rates off 100% — tracked as the next implementation
slice.

## Reliability findings

These are real harness constraints the benchmark surfaced (see also
`docs/benchmarks/heldout-oss-36-live.md`):

- **Cursor modes require a short workspace path.** In an earlier repro under a deeply
  nested (~140-char) sandbox path, `cursor-agent --trust` failed with
  `Failed to trust workspace … check permissions`, silently zeroing `cursor-agent`
  and `legion-cursor` (0/N, no edits). Re-running under a short `/tmp` path fixed it
  (38/38 here). Always run the live bench with a short `LEGION_BENCH_DIR`; CI uses the
  short `$RUNNER_TEMP`.
- **The untrusted delegate has a small empty-diff failure mode.** On the parity-floor
  corpus `legion-delegate` left one stub unedited (1/36), a no-op diff under
  `--untrusted --sandbox workspace-write`; the W3 learning bridge recorded it as a
  `legion-delegate`-attributed outcome. On this harder, better-specified tier it did
  not recur (38/38). Worth watching as a reliability tax of the untrusted path.
