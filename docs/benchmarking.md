# Legion Benchmark Workbench

Legion needs a Harness Bench-style workbench so improvements are measured, not
just felt. The goal is to run the same task suite before and after a routing,
skill, orchestration, or self-learning change and keep only changes that improve
the scorecard without hiding cost or latency regressions.

`legion-bench` now implements the first deterministic slice of that workbench:
offline scorecards plus fixture-backed task runs. There are no mandatory live
model calls, hosted service, or LLM judge in v1, but task cases run real Legion
CLIs against temporary workspaces and validate their artifacts.

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
| `core` | Did baseline trigger, route, validation, and self-improvement contracts hold? | observability/router triggers, frontend-review/docs-edit routing, marketplace/schema checks, session correction learning, self-learning memory |
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

Implemented CLI:

```bash
legion-bench run --suite core --repo . --json
legion-bench compare --baseline runs/base.json --candidate runs/candidate.json
legion-bench gate --baseline runs/base.json --candidate runs/candidate.json
```

`run` writes a durable benchmark artifact under
`~/.claude/logs/legion/bench/` with:

- case ID and suite
- prompt/task
- selected skills/entities for eval cases
- selected executor/model/sandbox/effort for route cases
- doctor validation commands and output
- fixture-backed task command output and artifact validators
- token/cost/latency fields, currently zero-cost/offline in v1
- final status and failure reason

The v1 suite files are JSON, not YAML, to keep package runtime dependencies to
the Python standard library:

```json
{
  "schema": "legion.bench.suite.v1",
  "suite": "core",
  "cases": [
    {
      "id": "eval.plugin.observability",
      "type": "eval",
      "scope": "plugin",
      "prompt": "Show per-executor cost success latency spans.",
      "expect_type": "plugin",
      "expect": "legion-observability",
      "required": true
    },
    {
      "id": "route.frontend-review",
      "type": "route",
      "archetype": "frontend-review",
      "expect": {
        "executor": "codex",
        "model": "gpt-5.5",
        "sandbox": "read-only"
      },
      "required": true
    },
    {
      "id": "doctor.telemetry-schema",
      "type": "doctor",
      "only": "telemetry-schema",
      "required": true
    },
    {
      "id": "task.session-correction-learning",
      "type": "task",
      "files": {
        "home/.codex/sessions/legion/session.jsonl": "{\"payload\":{\"type\":\"user_message\",\"content\":\"wrong attribution source\"}}\n"
      },
      "command": [
        "{repo}/legion-observability/bin/legion-session-learn",
        "--home",
        "{home}",
        "--logs",
        "{logs}",
        "--record",
        "--json"
      ],
      "validators": [
        {
          "type": "jsonl_contains",
          "path": "{logs}/self-learn/outcomes.jsonl",
          "match": {
            "source": "session-learn"
          }
        }
      ],
      "required": true
    }
  ]
}
```

## Metrics

Current v1 scorecard:

- `cases`
- `pass`
- `fail`
- `eval_hit_at_1`
- `eval_hit_at_k`
- `eval_miss`
- `eval_collision`
- `route_match_rate`
- `task_pass_rate`
- `validation_pass_rate`
- `false_success`
- `cost_usd`
- `duration_ms`
- `tokens`

Future live suites should add `orchestration_match`, validator-specific
pass/fail labels, and real cost/token/latency from delegated runs.

Gate rule:

- candidate must not reduce pass rate;
- candidate must not increase false success;
- candidate must improve at least one targeted metric, or stay neutral with an
  explicit reason;
- cost/latency regressions must be visible even when quality improves.

## Learning Loop

Benchmark misses can become normal self-learning input:

```bash
legion-bench run --suite core --repo . --record-failures
```

Then:

```bash
legion-self-learn run --repo . --apply-memory --quiet
```

`--record-failures` writes failed required cases as `legion.outcome.v1` rows with
`source: legion-bench` under `~/.claude/logs/legion/self-learn/outcomes.jsonl`.
Those outcomes remain memory/proposal input only. Source mutation stays behind
the existing `--apply-source` scorecard gate.

## Implementation Slices

1. Done: add a `legion-bench` CLI with fixture loading and JSON output.
2. Done: add `legion-observability/bench/core.json` for trigger, route,
   validation, and self-improvement task checks.
3. Done: reuse `legion-eval`, `legion-route`, `legion-doctor`, and spans.
4. Done: add `compare` and `gate` subcommands.
5. Done: write failed required cases into self-learning outcomes with
   `--record-failures`.
6. Next: add wider suites for orchestration, richer validation failure fixtures,
   and optional live model runs.
7. Next: add CI optional workflow or manual `workflow_dispatch` for full
   benchmark runs.

## Non-goals

- Do not require a hosted server for v1.
- Do not make live model runs mandatory for every PR.
- Do not auto-merge source mutations from benchmark results.
- Do not hide cost regressions behind aggregate pass rates.
