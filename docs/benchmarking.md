# Legion Benchmark Plan

Legion needs a Harness Bench-style workbench so improvements are measured, not
just felt. The goal is to run the same task suite before and after a routing,
skill, orchestration, or self-learning change and keep only changes that improve
the scorecard without hiding cost or latency regressions.

This is a follow-up plan, not the current implementation.

## Goals

- Benchmark Legion as a harness layer over Codex, Claude Code, Cursor, and future
  agent CLIs.
- Measure whether Legion selected the right skills, executor, orchestration
  pattern, validation gate, and final artifact.
- Feed failures into `legion-self-learn` as structured outcomes.
- Make benchmark runs reproducible enough for PR gates and daily regression
  checks.

## Benchmark Suites

Start with small deterministic fixtures before adding live model runs:

| Suite | What it measures | Example cases |
|---|---|---|
| `skill-routing` | Did the right skill/plugin trigger? | docs edit, auth bug, OSS readiness, benchmark planning |
| `orchestration` | Did Legion choose self/delegate/review/fanout correctly? | small fix, risky refactor, broad docs sweep |
| `validation` | Did it run the right gates and reject bad output? | missing test, shellcheck warning, invalid skill frontmatter |
| `learning-feedback` | Did user corrections/session logs become outcomes and hints? | wrong attribution, missed repo-specific instruction |
| `cost-routing` | Did routing improve cost at equal quality? | cheap model pass, stronger review, low-credit fallback |

Each case should include:

- prompt/task
- expected target entity
- expected executor or orchestration pattern
- required skills/plugins
- fixture repo state
- validator command
- expected pass/fail labels
- optional max cost/latency budget

## Command Shape

Proposed CLI:

```bash
legion-bench run --suite skill-routing --repo . --json
legion-bench compare --baseline runs/base.json --candidate runs/candidate.json
legion-bench gate --baseline runs/base.json --candidate runs/candidate.json
```

`run` writes a durable benchmark artifact under
`~/.claude/logs/legion/bench/` with:

- case ID and suite
- prompt/task
- selected skills/entities
- selected executor/model
- orchestration mode
- validation commands and results
- token/cost/latency from spans
- final status and failure reason

## Metrics

Minimum useful scorecard:

- `cases`
- `pass`
- `fail`
- `skill_hit_at_1`
- `skill_hit_at_k`
- `orchestration_match`
- `validation_pass`
- `false_success`
- `cost_usd`
- `duration_ms`
- `tokens`

Gate rule:

- candidate must not reduce pass rate;
- candidate must not increase false success;
- candidate must improve at least one targeted metric, or stay neutral with an
  explicit reason;
- cost/latency regressions must be visible even when quality improves.

## Learning Loop

Benchmark misses should become normal self-learning input:

```bash
legion-self-learn record \
  --entity plugin:legion-observability \
  --severity medium \
  --source legion-bench \
  --summary "skill-routing case oss-credits picked the wrong provenance source" \
  --evidence "<bench artifact path>"
```

Then:

```bash
legion-self-learn run --repo . --apply-memory --quiet
```

The first version should only record outcomes and proposals. Source mutation
stays behind the existing `--apply-source` scorecard gate.

## Implementation Slices

1. Add a `legion-bench` CLI with fixture loading and JSON output.
2. Add `legion-observability/bench/*.yaml` suites for skill routing,
   orchestration, validation, and feedback learning.
3. Reuse `legion-eval`, `legion-doctor`, and spans instead of inventing a second
   metrics format.
4. Add `compare` and `gate` subcommands.
5. Wire benchmark misses into `legion-self-learn record`.
6. Add CI optional workflow or manual `workflow_dispatch` for full benchmark
   runs.

## Non-goals

- Do not require a hosted server for v1.
- Do not make live model runs mandatory for every PR.
- Do not auto-merge source mutations from benchmark results.
- Do not hide cost regressions behind aggregate pass rates.
