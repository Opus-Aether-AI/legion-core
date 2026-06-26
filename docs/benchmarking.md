# Legion Benchmark Workbench

Legion needs a Harness Bench-style workbench so improvements are measured, not
just felt. The goal is to run the same task suite before and after a routing,
skill, orchestration, or self-learning change and keep only changes that improve
the scorecard without hiding cost or latency regressions.

`legion-bench` now implements two deterministic lanes: a fast `core` smoke suite
and a broader `stable` suite for PR/release confidence. There are no mandatory
live model calls, hosted service, Docker images, or LLM judge in the default
lanes, but task cases run real Legion CLIs against temporary workspaces and
validate their artifacts.

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
| `stable` | Did the full deterministic harness contract stay stable across repeated runs? | `core` plus every routing archetype, all Legion plugin/skill triggers, extra doctor checks, trace/route CLI contracts |
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
legion-bench run --suite stable --repo . --json --strict
legion-bench stable --suite stable --repo . --repeat 3 --strict
legion-bench corpus --corpus local-smoke --repo . --json
legion-bench compare --baseline runs/base.json --candidate runs/candidate.json
legion-bench gate --baseline runs/base.json --candidate runs/candidate.json
legion-bench learning-lift --repo . --json
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

`stable` runs the same suite multiple times and writes
`~/.claude/logs/legion/bench/stability/<run-id>.json` with:

- iterations and case-runs
- min/mean/max score and pass rate
- per-dimension pass rates
- flake cases, defined as the same case producing inconsistent statuses
- the run artifact path for every iteration

`corpus` is the live A/B layer. A corpus defines cases, validators, and harness
modes, then runs every selected mode on the same cases:

```bash
legion-bench corpus \
  --corpus ./bench/corpora/my-live-corpus.json \
  --mode direct-codex \
  --mode legion-delegate \
  --baseline direct-codex \
  --require-reliable \
  --json
```

Each mode can be any command: direct Codex, direct Claude Code, Cursor Agent,
`legion-delegate`, `legion-orchestrate`, an Aider runner, or a SWE-bench wrapper.
The runner writes per-case workspaces and artifacts under
`~/.claude/logs/legion/bench/corpus/`, captures stdout/stderr, validates files or
JSON/JSONL, and aggregates pass rate, duration, cost, tokens, and span count.
Relative lift is only marked reliable once the comparison has at least
`reliability_min_cases` case-runs, default `30`.
See `legion-observability/bench/corpora/README.md` for a direct-Codex versus
`legion-delegate` live corpus template.

`compare` reports Harness Bench-style lift fields for the headline score:

- `delta_pct_points`: absolute score movement, e.g. `0.79 -> 0.93` is
  `+14.0` percentage points.
- `relative_improvement_pct`: relative lift, e.g. `(0.93 - 0.79) / 0.79`
  is `+17.722%`.

`learning-lift` is a deterministic smoke benchmark for the self-learning path.
It writes one session correction fixture, scores the same probes before and
after `legion-session-learn --record` plus `legion-self-learn run
--apply-memory`, and then compares the two normal benchmark artifacts. This is
useful for proving the measurement path; it is not a broad task-corpus result.
For the small fixture, use the percentage-point delta as the headline. Relative
lift is denominator-sensitive and is marked unreliable until the corpus has at
least 30 cases.

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
- `learning_pass_rate`
- `route_match_rate`
- `task_pass_rate`
- `validation_pass_rate`
- `false_success`
- `cost_usd`
- `duration_ms`
- `tokens`
- `dimensions`

Current stable rollup metrics:

- `iterations`
- `cases_per_iteration`
- `total_case_runs`
- `min_score`
- `mean_score`
- `max_score`
- `min_pass_rate`
- `mean_pass_rate`
- `max_pass_rate`
- `flake_count`
- `required_fail_total`

Current corpus metrics:

- per-mode `case_runs`, `pass`, `fail`, `pass_rate`
- per-mode `required_fail`
- per-mode `duration_ms`, `cost_usd`, `tokens`, `span_count`
- per-dimension pass rates
- baseline-vs-candidate `delta_pct_points`
- baseline-vs-candidate `relative_improvement_pct`
- reliability flag based on sample size

Future live suites should add `orchestration_match`, validator-specific
pass/fail labels, and real cost/token/latency from delegated runs. Live suites
should follow the OSS pattern:

- Harness Bench: criterion-level before/after scoring and trace-backed
  improvement loops.
- SWE-bench: reproducible repo/task artifacts and isolated evaluation.
- Aider benchmark: durable run records with pass rates, commit hash, settings,
  cost/time, and malformed-output counters.

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
6. Done: add `learning-lift` to report before/after self-learning percentage
   lift on an isolated fixture.
7. Done: add `stable.json` plus `legion-bench stable` for repeated-run
   deterministic gating and flake detection.
8. Done: add `legion-bench corpus`, a generic A/B corpus runner for real
   direct-harness vs Legion measurements with sample-size reliability flags.
9. Next: add packaged optional adapters for SWE-bench Lite/Verified,
   Aider Polyglot-style exercises, and Legion-specific fixture repos.
10. Next: add CI optional workflow or manual `workflow_dispatch` for full
   benchmark runs.

## Non-goals

- Do not require a hosted server for v1.
- Do not make live model runs mandatory for every PR.
- Do not auto-merge source mutations from benchmark results.
- Do not hide cost regressions behind aggregate pass rates.

## References

- [svineet/harness-bench](https://github.com/svineet/harness-bench) — criterion-level harness workbench with observe/analyze/improve loops.
- [SWE-bench](https://github.com/swe-bench/SWE-bench) — reproducible repository-level coding issue evaluation; useful model for future live corpus adapters.
- [Aider benchmark harness](https://github.com/Aider-AI/aider/blob/main/benchmark/README.md) — durable benchmark run records with pass rates, commit/settings, cost, time, and malformed-output counters.
