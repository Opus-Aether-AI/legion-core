# Heldout OSS 36 — Live Benchmark (correctness-parity floor)

Generated: 2026-06-27. **Single commit, single run** (no cross-commit reruns).
Bench root under a short `/tmp` path so cursor modes trust their workspace.

`heldout-oss-36` is the parity floor: 36 single-function Python micro-tasks that
every frontier model saturates at ~100%. It is **not** a model-quality claim and
cannot show one harness beating another — its jobs are (1) prove a harness does not
*regress* raw correctness and (2) give a real per-mode **cost** reference. For lift,
see the discriminating tier in `heldout-oss-hard-live.md`.

> Supersedes the earlier version of this file, which reported `$0` for direct
> modes (no spans) and stitched a separately-rerun `direct-claude` from a different
> commit. Direct adapters now emit real `legion.span.v1` cost/tokens, and this run
> is a single matrix at one commit. (Claude was omitted from this refresh to save
> spend on a saturated floor; its parity is established on the hard tier.)

## Command

```bash
LEGION_BENCH_DIR=/tmp/lm-XXXX/bench LEGION_TELEMETRY_DIR=/tmp/lm-XXXX/spans \
legion-observability/bin/legion-bench corpus --corpus heldout-oss-36 --repo . \
  --mode direct-codex --mode cursor-agent \
  --mode legion-delegate --mode legion-cursor \
  --baseline direct-codex --repeat 1 --record-failures \
  --report-md /tmp/lm-XXXX/heldout-oss-36-live.md --json
```

## Results

| Mode | Pass | Case-runs | Pass rate | 95% CI | Cost | Tokens | Mean ms | P95 ms |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| `cursor-agent` | 36 | 36 | 1.000 | 0.904-1.000 | `$0.000000` (unmetered) | 3646747 | 25224 | 32051 |
| `direct-codex` | 36 | 36 | 1.000 | 0.904-1.000 | `$3.245539` | 3390921 | 30365 | 37552 |
| `legion-cursor` | 36 | 36 | 1.000 | 0.904-1.000 | `$0.000000` (unmetered) | 3975836 | 27956 | 37704 |
| `legion-delegate` | 35 | 36 | 0.972 | 0.858-0.995 | `$3.549048` | 3617370 | 40820 | 64576 |

Baseline `direct-codex`:

| Comparison | Delta pp | McNemar p | Cost delta | Duration delta ms |
|---|---:|---:|---:|---:|
| `direct-codex..cursor-agent` | +0.000 | n/a | `$-3.245539` | -185074 |
| `direct-codex..legion-cursor` | +0.000 | n/a | `$-3.245539` | -86718 |
| `direct-codex..legion-delegate` | -2.778 | 1.000000 | `$+0.303509` | +376381 |

### Failure cluster

| Mode | Dimension | Count | Case |
|---|---|---:|---|
| `legion-delegate` | data-transform | 1 | `py-merge-counts` |

## Interpretation

- **Parity holds where it can.** Every direct executor is 36/36; `legion-cursor` is
  36/36. The benchmark confirms the Legion wrappers do not regress raw correctness on
  the floor.
- **One real reliability tax, surfaced and recorded.** `legion-delegate` left
  `py-merge-counts` unedited (35/36) — a no-op/empty diff under the `--untrusted`
  sandbox, not a wrong answer (`direct-codex` solved it). The miss is **not
  statistically significant** on this sample (McNemar p = 1.0), but it is a concrete
  failure: the untrusted delegate path occasionally produces no edit on a trivial
  task. The `--record-failures` learning bridge wrote it to
  `self-learn/outcomes.jsonl` as a `command:legion-delegate` outcome — the
  learning-feedback loop demonstrated end-to-end on real data.
- **Cost is now real on every mode.** `direct-codex` $3.25, `legion-delegate` $3.55
  (a `+$0.30` wrapper delta), cursor modes `$0` (unmetered subscription). No more `$0`
  direct-adapter columns hiding the cost axis.

## Reliability findings

- **Cursor needs a short workspace path** — `cursor-agent --trust` fails on very
  long / deeply nested paths (zeroing the cursor modes). Run with a short
  `LEGION_BENCH_DIR`; CI uses `$RUNNER_TEMP`.
- **Latency tax** — the delegate's isolated-worktree + verify loop is slower
  (mean 40.8s vs 30.4s; P95 64.6s vs 37.6s) for the cost it saves on the hard tier.
