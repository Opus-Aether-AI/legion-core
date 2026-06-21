# legion-orchestrate

Legion's dynamic **multi-model** orchestrator — the ultracode loop, but Opus conducts while **GPT-5.4 does the bulk of coding in parallel** and **GPT-5.5 verifies**.

> Decompose → fan out (GPT-5.4, parallel) → cross-model verify (GPT-5.5) → synthesize → gate.

## `legion-fanout`

Run many scoped slices in **parallel** across executors and collect verified diffs + cost:

```bash
printf '%s\n' \
  '{"archetype":"implement-feature","task":"build the X module per <spec>"}' \
  '{"archetype":"write-tests","task":"unit tests for X"}' \
  '{"archetype":"deep-reasoning","task":"decide the data model"}' \
  | legion-fanout --slices - --repo . --max-concurrency 4
```

- GPT-5.4/5.5 slices run in parallel git worktrees via `legion-delegate`; `self`/`deep-reasoning` slices return `status:"inline"` for Opus to do.
- Output: per-slice `{status, model, diff_path, cost_usd}` + totals + `by_model` + `total_cost_usd`.
- Bounded by `--max-concurrency` (or `LEGION_MAX_CONCURRENCY`, default 4). Portable to bash 3.2.

## The playbook + ultracode mode

`SKILL.md` is the orchestration playbook (decompose → fan out → cross-model verify → synthesize → gate). `LEGION_ULTRACODE=1` goes maximally exhaustive: wide fan-out, multi-vote verify (GPT-5.5 **and** Opus must approve), loop-until-dry — all metered, kept ≥50% codex via `legion-share`.

## Depends on

`legion-router` (`legion-delegate`, `legion-route`, `routing.toml`) and `legion-observability` (`legion-trace`, `legion-share`). Requires `codex` (authenticated), `jq`, `git`.
