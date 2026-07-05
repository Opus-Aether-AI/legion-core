# legion-orchestrate

Legion's dynamic **multi-model** orchestrator — the ultracode loop, but Claude conducts while the configured Codex workhorse does the bulk of coding in parallel and the configured Codex reviewer verifies.

> Decompose → fan out (configured Codex, parallel) → cross-model verify (configured reviewer) → synthesize → gate.

## `legion-fanout`

Run many scoped slices in **parallel** across executors and collect verified diffs + cost:

```bash
printf '%s\n' \
  '{"archetype":"implement-feature","task":"build the X module per <spec>"}' \
  '{"archetype":"write-tests","task":"unit tests for X"}' \
  '{"archetype":"deep-reasoning","task":"decide the data model"}' \
  | legion-fanout --slices - --repo . --max-concurrency 4
```

- Codex slices run in parallel git worktrees via `legion-delegate`; `self`/`deep-reasoning` slices return `status:"inline"` for Claude to do.
- Output: per-slice `{status, model, diff_path, cost_usd}` + totals + `by_model` + `total_cost_usd`.
- Bounded by `--max-concurrency` (or `LEGION_MAX_CONCURRENCY`, default 4). Portable to bash 3.2.

## The playbook + ultracode mode

`SKILL.md` is the orchestration playbook (decompose → fan out → cross-model verify → synthesize → gate). `LEGION_ULTRACODE=1` goes maximally exhaustive: wide fan-out, multi-vote verify (configured Codex reviewer **and** Claude must approve), loop-until-dry — all metered, kept ≥50% codex via `legion-share`.

## Depends on

`legion-router` (`legion-delegate`, `legion-route`, `routing.toml`) and `legion-observability` (`legion-trace`, `legion-share`). Requires `codex` (authenticated), `jq`, `git`.
