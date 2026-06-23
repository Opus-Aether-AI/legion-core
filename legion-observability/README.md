# legion-observability

See everything Legion's multi-model runs do — per-executor **cost, success rate, and latency** — verify the install is wired correctly, and turn failures into measured harness improvement experiments.

> One orchestrator, a legion of models — and one telemetry stream for all of them.

## Tools

| Bin | Script | What it does |
|---|---|---|
| `legion-report` | `scripts/legion-report.sh` (+ `legion-aggregate.py`, `legion-render.py`) | Cost / success-rate / p50-p95 latency, grouped by executor/model/status, as a TUI table or `--html`. |
| `legion-trace` | `scripts/legion-telemetry.sh` | `emit` a validated span; `validate` a span file/stream. |
| `legion-otel-export` | `scripts/legion-otel-export.py` | Map `legion.span.v1` → OTLP/HTTP; POST to `$OTEL_EXPORTER_OTLP_ENDPOINT` (no-op until set; `--dry-run` to preview). |
| `legion-doctor` | `scripts/legion-doctor.sh` | CI-usable verifier; exits nonzero on any hard-check failure. |
| `legion-catalog` | `scripts/legion-catalog.py` | Read-only inventory of plugins, skills, agents, commands, hooks, and MCPs. |
| `legion-self-learn` | `scripts/legion-self-learn.py` | Daily self-learning loop: spans + review findings + trigger evals + manual bug records -> entity-scoped memory/proposals; optional source candidates run in isolated copies and are kept only on measured scorecard improvement. |
| `legion-context-profile` | `scripts/legion-context-profile.py` | Reversibly trim active Codex/.agents skills and Claude plugins to a repo profile when context budget gets noisy. |
| `legion-session-learn` | `scripts/legion-session-learn.py` | Mine recent Claude/Codex/Cursor sessions and project memories for recurring gotchas, then optionally record them into self-learning outcomes. |

## Quick start

```bash
legion-doctor                       # is the install wired correctly?
legion-report                       # per-executor cost / success / latency
legion-report --by model --html > report.html
cat ~/.claude/logs/legion/spans/*.jsonl | legion-otel-export --dry-run | jq .
legion-self-learn run --apply-memory       # safe daily mode
legion-self-learn hints                    # active learned guardrails
legion-context-profile apply --dry-run     # preview skill/plugin context trim
legion-session-learn --query moneyball --record

# Emit a span from any runner/executor:
legion-trace emit --executor codex --model gpt-5.5 --status ok \
  --cost 0.05 --duration-ms 1800 --tokens '{"input_tokens":12000}'
```

## The span contract

`schema/legion.span.v1.schema.json` — required `schema, ts, run_id, executor, model, status`; plus `cost_usd`, `duration_ms`, `tokens`, `trace_id`/`parent_id` (trace trees), `target_type`/`target_name` (self-learning attribution), `artifacts`. `legion-delegate` already emits it.

## Self-learning loop

The loop follows the harness-bench/autoresearch shape:
observe -> analyze -> propose -> baseline -> isolate -> mutate -> score -> keep/discard.

- **Observe:** read durable spans, review verdict artifacts, trigger eval misses, routing optimizer advice, and manual `legion-self-learn record` bug reports.
- **Analyze:** attach every outcome to a catalog entity (`plugin`, `skill`, `command`, `agent`, `hook`, or `mcp`) so slash commands and sub-agents improve too.
- **Score:** run plugin + entity `legion-eval` datasets and `legion-doctor`, then persist metrics in `experiments.tsv`.
- **Experiment:** source edits are opt-in (`--apply-source`); candidates run in isolated temp copies and only the best measured improvement is applied to the real checkout. Trigger fixes update markdown frontmatter or marketplace descriptions so the scorecard can measure them.

The installed daily `legion-refresh` cron runs:

```bash
legion-self-learn run --apply-memory --quiet
```

That mode is active but conservative: it updates memory/proposals and scorecard
ledgers without silently rewriting vendored or source harness files. Unresolved
outcomes remain active until a kept source experiment resolves them.

## Layout

```
legion-observability/
├── bin/{legion-report,legion-doctor,legion-trace,...} # PATH shims
├── schema/legion.span.v1.schema.json                 # the telemetry contract
├── scripts/
│   ├── legion-telemetry.sh     # emit + validate spans
│   ├── legion-aggregate.py     # roll up spans -> per-group metrics
│   ├── legion-render.py         # aggregate JSON -> TUI / HTML
│   ├── legion-report.sh         # aggregate | render
│   ├── legion-otel-export.py    # spans -> OTLP/HTTP trace tree
│   ├── legion-self-learn.py     # daily self-learning memory/proposals
│   └── legion-doctor.sh         # install verifier
└── SKILL.md
```

## Tests

- `tests/telemetry.bats`, `tests/doctor.bats` (bash, run under the repo BATS suite).
- `tests/python/` — Python unit tests for aggregation, catalog, eval, context tuning, self-learning, and export; run `bash tests/python/run-tests.sh` (uvx pytest).

## Env

- `LEGION_TELEMETRY_DIR` — span dir (default `~/.claude/logs/legion/spans`).
- `OTEL_EXPORTER_OTLP_ENDPOINT` — enables real OTLP export; unset = no-op.
