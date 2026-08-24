# gpt-5.6-luna @ max vs gpt-5.6-terra @ high

Run 2026-08-25 on this machine, `direct-codex` mode, Codex on a ChatGPT Pro
subscription. Prices are the published standard-tier rates as corrected in
`legion-router/config/costs.json`; on a subscription they are imputed, not billed.

The question was whether the cheap role at maximum reasoning matches the
workhorse at `high`. It could not previously be asked: the bench adapter had no
reasoning-effort control, and telemetry shows the cheap model had never been run
above `low` — 19 lifetime runs, all `scout`/`cheap-bulk`, reasoning at ~5% of
output.

## Result

| corpus | cases | terra@high | luna@max | cost ratio | latency |
|---|---|---|---|---|---|
| aider-polyglot-python | 34 | 34/34 · $3.5277 | 34/34 · $0.6290 | **5.6x cheaper** | 1.56x |
| heldout-oss-hard | 19 | 19/19 · $0.8426 | 19/19 · $0.1405 | **6.0x cheaper** | 1.49x |

**53 matched cases, zero disagreements.** Not one case where the two models
differed on pass/fail.

Luna at `max` spends 4.08x the reasoning tokens terra spends at `high`
(98,916 vs 24,230 on polyglot) and roughly 2x the output tokens. It is still
5-6x cheaper because the per-token price is 10x lower, so the extra thinking
does not come close to closing the gap. The cost of that thinking is latency:
about 1.5x on both corpora.

## What this does NOT establish

**Both corpora saturate.** Terra scores 100% on each, including the one whose
description says it was authored to discriminate where saturated benchmarks
cannot. A corpus on which the baseline is perfect can only measure cost; it
cannot rank quality, and "no disagreements" across 53 cases means both models sat
on the ceiling, not that they are equal on work that is actually hard.

So this result supports the cheap role — and any archetype whose difficulty is in
the range these corpora cover — running at higher effort for a 5-6x saving. It
does not settle whether the cheap model can carry `implement-feature` or
`fix-bug` on a real repository.

Settling that needs a corpus with headroom. DeepSWE (113 contamination-free
tasks, Apache-2.0, hand-written behavioural verifiers) tops out at 74% for the
best model on its own leaderboard, so it has the room these two lack, and its
Pier harness drives `codex`, `claude-code` and `opencode` directly.

## Reproducing

```bash
CODEX_MODEL=gpt-5.6-terra CODEX_REASONING_EFFORT=high \
  legion-bench corpus --repo . --corpus <corpus>.json \
  --mode scripted-baseline --mode direct-codex --run-id <id> --json
```

The corpus runner writes its summary to stdout only, so an interrupted run loses
the aggregate. It does not lose the evidence: each case leaves a workspace whose
validators are plain commands, and a span carrying model, status, duration,
tokens and cost. The terra/polyglot arm here was scored that way after its
process was killed, rather than re-run — which matters when the resource being
measured is quota.
