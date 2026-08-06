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

- normalize Claude, Codex, Cursor, opencode, and Gemini session JSONL into
  versioned, harness-neutral events;
- group events into sessions and episodes, classify explicit user decisions,
  and link each decision to later verification or failure evidence;
- score five behavior axes and 14 repository-quality dimensions with named,
  deterministic scorers;
- promote a behavior into a global law only after at least three episodes in
  two projects, retiring laws when the current evidence no longer supports them;
- mine spans, review findings, trigger misses, routing advice, and manual bugs;
- attach every outcome to a catalog entity;
- write durable entity-scoped hints and proposals;
- run a deterministic baseline scorecard (`legion-eval` plugin + entity datasets
  and `legion-doctor`);
- keep source proposals typed and maintainer-eligible; and
- hand source changes to the separate, review-only `legion-improve` engine.

## What It Observes

- Evidence-linked reports produced by `legion-learn analyze`, including promoted
  `legion.learning-law.v1` records. Stable schemas live under
  `legion-observability/schema/`.
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
legion-learn analyze --repo . --repo-only --lookback-days 30 --json
legion-learn report --repo .
legion-learn laws --repo .
legion-learn explain test-real-workflow --repo .
legion-learn export --repo . > redacted-learning-report.json
legion-session-learn --repo . --harness codex --role user --query "wrong source" --json
legion-session-learn --repo . --query "review was interrupted" --show-evidence
```

`--repo` uses session cwd and Git remote provenance rather than searching
transcript text for a project name. System/developer messages and tool results
are excluded unless explicitly selected. `--show-evidence` displays
best-effort-redacted snippets and home-relative paths for local inspection;
inspect the output before sharing it. Durable outcomes remain transcript-free.

`legion-learn` streams raw JSONL and discards it. Durable v2 reports contain
bounded, best-effort-redacted excerpts and hashed dispatch prompts; credentials,
private-key blocks, email addresses, connection URLs, and local absolute paths
are removed before state is written. Reports remain local unless the operator
exports or shares them.
Review any export before sending it elsewhere.

The behavior axes are execution leverage, steering, engineering quality,
product thinking, and planning. Repository scoring covers commit discipline,
tests, code quality, error handling, security, architecture, documentation,
agent configuration, infrastructure, dependencies, Git workflow, evolution,
performance awareness, and production readiness. Every behavior score carries
evidence IDs, a confidence level, and its scorer name.

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
legion-learn analyze --repo ~/.agents/sources/legion-core
legion-session-learn --repo ~/.agents/sources/legion-core --record
legion-self-learn run --repo ~/.agents/sources/legion-core --apply-memory --quiet
# Only when explicitly configured:
legion-improve queue --repo ~/.agents/sources/legion-core --base-ref main --mode draft --max 1 --json
```

The first step writes the project report under
`<state_root>/learning/reports/` and the cross-project law store under
`~/.legion/global/learning/`. Evidence provenance and cross-project aggregation
use a normalized Git remote when available. Existing operational state remains
path-keyed for upgrade compatibility; `legion-state` exposes both the legacy
`project_id` and clone-stable `repository_project_id` identities.

This writes under the project `state_root` reported by
`legion-state --repo ~/.agents/sources/legion-core`:

- `self-learn/harness-memory.json`
- `self-learn/reports/<date>.json`
- `self-learn/experiments.md`
- `self-learn/experiments.tsv`
- `self-learn/improvement-queue/<proposal-fingerprint>.json`
- `improve/runs/<proposal-fingerprint>.json` after an improvement mode processes it

Memory mode is intentionally safe: it does not rewrite source or vendored skills.
The default cron run scans all available spans and manual records so bugs recorded
after yesterday's cron are still ingested. Passing `--day YYYY-MM-DD` keeps an
exact UTC-day report window for reproducible audits and tests. Durable memory
preserves unresolved hints until a kept source experiment resolves them.

The evidence and compatibility session-learning steps are separately bounded.
The evidence lane defaults to the newest 100 eligible files, 64 MiB in aggregate,
and 20,000 normalized events; tune those limits with
`LEGION_EVIDENCE_LEARN_MAX_FILES`, `LEGION_EVIDENCE_LEARN_MAX_TOTAL_MB`, and
`LEGION_EVIDENCE_LEARN_MAX_EVENTS`. Repository-only analysis applies those limits
after provenance filtering while bounding candidate discovery to the newest 1,000
files and 256 MiB. Set `LEGION_EVIDENCE_LEARN=0` or `LEGION_SESSION_LEARN=0` to
disable either refresh lane. The compatibility lane uses the newest 100 eligible
sources. Run
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

## Review-only source improvement

`legion-self-learn --apply-source` is retained only as a compatibility dry-run
and cannot mutate a checkout. To evaluate an approved typed proposal, use:

```bash
legion-improve run --repo . --proposal proposal.json --state-dir .legion/improve --mode draft --json
```

`legion-improve` defaults to `off`; `dry-run` never creates a PR; and `draft`
is the only publishing mode. It freezes the remote identity and base SHA,
creates an isolated worktree, allows only a native Markdown-guardrail mutation,
checks a bounded single-file diff, and runs immutable baseline and candidate
gates repeatedly. Any baseline/candidate variance or candidate regression is
rejected. The proposal cannot supply a command. A bounded receipt from the
external `legion-delegate review` boundary over exact base/head SHAs is required
before an idempotent draft PR is created through `gh`. It never merges, deploys,
or writes to the operator checkout.

Only active cross-project laws with confidence at least `0.9`, five supporting
episodes, three projects, a bounded guidance string, and a safe non-vendored
Markdown target enter this queue. Other observations still improve executor
outputs through scoped memory, but cannot propose source changes.

The daily refresh processes no source proposal by default. To enable the
review-only automation explicitly:

```bash
export LEGION_IMPROVE_MODE=dry-run  # evaluate + independent review, no PR
export LEGION_IMPROVE_MODE=draft    # additionally create a draft PR
export LEGION_IMPROVE_MAX=1         # bounded proposals per refresh
```

The refresh bases candidates on the exact remote `main` tip even when the
installed source clone is detached at a stable release tag. Auto-update remains
the separate release-pinned refresh step. A draft improvement still needs a
working reviewer/model login and `gh` authentication.

Durable state stores only bounded IDs, hashes, and summaries, so it is safe to
inspect/replay after interruption without preserving prompts, outputs,
credentials, or local checkout paths.

## Harness Parity Features

- **Baseline scorecard:** every run records aggregate `cases`, `pass`, `miss`,
  `collision`, `precision_at_1`, `hit_at_k`, and `doctor_ok`.
- **Entity scorecards:** `legion-eval` covers marketplace plugins plus command,
  agent, and skill routing cases.
- **Candidate isolation:** `legion-improve` runs eligible source proposals in
  isolated worktrees and never touches the real checkout.
- **Hypothesis log:** every candidate records target, proposal IDs, hypothesis,
  score delta, status, and decision.
- **Keep/discard gate:** a candidate may only become a draft PR after stable,
  non-regressing repeated gates and an independent receipt.
- **Pass/fail contrast:** reports include success and failure examples by entity
  so future proposals can compare good and bad traces.
- **Resolved-state tracking:** outcomes remain evidence for future proposals;
  a draft PR does not silently resolve or apply them.

## Remaining Extensions

- Expand the Harness Bench-style workbench beyond the offline `core` suite; see
  [benchmarking.md](benchmarking.md).
- Add hook and MCP-specific eval datasets once there are enough stable examples.
- Add new typed mutators only when their path allowlists and scorecards
  can prove safety and improvement.
- Add evidence-backed scorers for new dimensions without changing existing
  versioned schema meanings.

## Consumption

Before working on Legion harness behavior or running workflow lanes, read active
hints:

```bash
legion-self-learn hints
legion-self-learn hints --entity skill:workflow-orchestrator
legion-self-learn hints --entity plugin:legion-router
```

## Typed executor context

Use the context compiler when a runner needs learning guidance. It reads project
and global `hints.json` collections, selects only trusted active hints, applies
exact/selector/global scope in that order, and emits a deterministic token- and
hint-bounded JSON document. Evidence, transcripts, excerpts, and other source
payload fields are intentionally never included.

```bash
legion-self-learn compile-context --repo . --entity skill:release --stage plan --json
```

`reconcile` migrates only legacy path identities whose repository basename
matches the canonical remote identity, deduplicates replayed evidence by ID, and
replaces the resulting state file atomically:

```bash
legion-self-learn reconcile --repo . --legacy-state legacy-state.json --evidence evidence.jsonl --json
```

These hints are failure evidence. They do not override the user, the repository's
`AGENTS.md`, or normal validation gates.

`legion-run` consumes this compiler at its planning boundary. It writes the
schema-valid context and usage artifacts even when no hint is selected, hashes
the immutable context as a revision, and carries only bounded trusted guidance
to delegated slice and final-review inputs. Its `learning-receipts.json`
records each delivery disposition and the deterministic-validation receipt;
it never carries raw transcripts or evidence excerpts.
