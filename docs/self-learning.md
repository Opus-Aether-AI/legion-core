# Legion Self-Learning Harness

Legion uses a local, conservative self-learning loop inspired by
[svineet/harness-bench](https://github.com/svineet/harness-bench)'s workbench
loop and [Karpathy's `autoresearch`](https://github.com/karpathy/autoresearch)
pattern:

```
observe -> analyze -> propose -> baseline -> isolate -> mutate -> score -> keep/discard
```

The loop is implemented by `legion-self-learn` in `legion-observability`.
The useful `autoresearch` abstraction for Legion is not "let agents rewrite
everything." It is a bounded experiment protocol: establish a baseline, run a
stable scorecard, record a compact ledger row, keep only measured improvements,
and discard failed or regressing mutations.

## Current Contract

Legion implements that protocol locally:

- mine spans, review findings, trigger misses, routing advice, and manual bugs;
- attach every outcome to a catalog entity;
- write durable entity-scoped hints and proposals;
- run a deterministic baseline scorecard (`legion-eval` plugin + entity datasets
  and `legion-doctor`);
- optionally test source mutations in isolated temp copies;
- keep only the best candidate that improves the score without metric
  regressions; and
- roll back the real checkout if the final scorecard fails or regresses.

## What It Observes

- `legion.span.v1` telemetry from the `telemetry_dir` reported by
  `legion-state --repo .`
- Review verdict artifacts referenced by spans
- `legion-eval` trigger misses/collisions
- `legion-optimize` accepted routing advice
- `legion-bench --record-failures` benchmark misses
- Session feedback mined by `legion-session-learn --record`, including explicit
  user corrections from Claude/Codex/Cursor logs. The default scan is bounded,
  excludes catalogs/tool results/subagents/benchmark-marked sources, deduplicates
  equivalent messages, and records only evidence counts and hashes.
- Manual bug records from:

```bash
legion-self-learn record --entity TYPE:NAME --summary "..."
```

For a repository-specific audit:

```bash
legion-session-learn --repo . --harness codex --role user --query "wrong source" --json
legion-session-learn --repo . --query "review was interrupted" --show-evidence
```

`--repo` uses session cwd and Git remote provenance rather than searching
transcript text for a project name. System/developer messages and tool results
are excluded unless explicitly selected. `--show-evidence` displays redacted
snippets and home-relative paths; durable outcomes remain transcript-free.

## What It Improves

Outcomes attach to catalog entities from `legion-catalog`, not only to model
routes:

- plugin
- skill
- command
- agent
- hook
- mcp

That means a bug found in `/feature`, a sub-agent, or a skill can become an
entity-scoped memory/proposal for the next run.

When a span includes `target_type` and `target_name`, that explicit metadata wins.
Otherwise Legion falls back to catalog token matching and manual records.

## Daily Active Mode

When enabled at install time, the `legion-core-refresh` cron runs:

```bash
legion-session-learn --repo ~/.agents/sources/legion-core --record
legion-self-learn run --repo ~/.agents/sources/legion-core --apply-memory --quiet
```

This writes under the project `state_root` reported by
`legion-state --repo ~/.agents/sources/legion-core`:

- `self-learn/harness-memory.json`
- `self-learn/reports/<date>.json`
- `self-learn/experiments.md`
- `self-learn/experiments.tsv`

Memory mode is intentionally safe: it does not rewrite source or vendored skills.
The default cron run scans all available spans and manual records so bugs recorded
after yesterday's cron are still ingested. Passing `--day YYYY-MM-DD` keeps an
exact UTC-day report window for reproducible audits and tests. Durable memory
preserves unresolved hints until a kept source experiment resolves them.

The preceding session-learning step is separately bounded to the newest 100
eligible sources. Set `LEGION_SESSION_LEARN=0` to disable it; run
`legion-session-learn --session-limit 0` manually only for an intentional
unbounded audit.

`experiments.tsv` is the daily scorecard and experiment ledger:

```tsv
date	commit	experiment_id	candidate_id	target	spans	outcomes	proposals	eval_cases	eval_pass	eval_miss	eval_collision	precision_at_1	hit_at_k	doctor_ok	baseline_score	candidate_score	delta	status	decision	description
```

This gives Legion the same operational discipline as an overnight research loop:
every baseline and candidate leaves a comparable row with scorecard metrics,
doctor status, delta, status, decision, and source commit. The CLI JSON payload
and `reports/<date>.json` file provide the report path for deeper inspection.

Setup bridges record failures into the same memory stream when Codex/Cursor MCP,
agent, skill, or CLI verification fails. That lets daily refresh learn from broken
installation paths, not only from model execution spans.

## Source Mutation Mode

Source mutation is explicit:

```bash
legion-self-learn run --apply-source
```

It creates isolated candidate copies, applies each mutable proposal, and scores
the candidate with:

- `legion-eval --repo <repo> --json`
- `legion-doctor --repo <repo>`

Only candidates with a positive score delta and no metric regressions are
eligible to be kept. Legion applies the best kept candidate to the real checkout,
reruns the scorecard, and rolls back if the final checkout fails or regresses.

Vendored files are skipped unless `--allow-vendored` is passed.

Two mutation families are supported today:

- command, agent, and skill trigger fixes patch markdown frontmatter
  `description` fields with measured trigger terms so entity scorecards can see
  the improvement;
- non-trigger markdown proposals get a `Learned Guardrails` block; and
- marketplace plugin trigger fixes patch `.claude-plugin/marketplace.json`
  descriptions with measured trigger terms.

## Harness Parity Features

- **Baseline scorecard:** every run records aggregate `cases`, `pass`, `miss`,
  `collision`, `precision_at_1`, `hit_at_k`, and `doctor_ok`.
- **Entity scorecards:** `legion-eval` covers marketplace plugins plus command,
  agent, and skill routing cases.
- **Candidate isolation:** source proposals run in isolated temp copies before
  touching the real checkout.
- **Hypothesis log:** every candidate records target, proposal IDs, hypothesis,
  score delta, status, and decision.
- **Keep/discard gate:** Legion keeps only measured improvements and discards
  failed, neutral, or regressing candidates.
- **Pass/fail contrast:** reports include success and failure examples by entity
  so future proposals can compare good and bad traces.
- **Resolved-state tracking:** outcome IDs are marked processed only after a
  kept source experiment resolves them. Unresolved bugs stay active in daily
  reports; `--include-processed` restores audit visibility for resolved items.

## Remaining Extensions

- Expand the Harness Bench-style workbench beyond the offline `core` suite; see
  [benchmarking.md](benchmarking.md).
- Add hook and MCP-specific eval datasets once there are enough stable examples.
- Expand source mutators beyond markdown guardrails and marketplace descriptions
  only when each mutator has a scorecard that can prove improvement.
- Persist richer Pareto-frontier trade-offs if future scorecards add independent
  quality, cost, and latency criteria.

## Consumption

Before working on Legion harness behavior or running workflow lanes, read active
hints:

```bash
legion-self-learn hints
legion-self-learn hints --entity skill:workflow-orchestrator
legion-self-learn hints --entity plugin:legion-router
```

These hints are failure evidence. They do not override the user, the repository's
`AGENTS.md`, or normal validation gates.
