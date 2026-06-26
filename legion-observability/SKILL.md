---
name: legion-observability
kind: ability
description: Use for "how much did that cost", "which model is winning", "is legion set up right", or "did this harness change improve" — Legion telemetry, `legion.span.v1` traces, bench, doctor, heal, and self-learn answers.
---

# Legion Observability — see everything

Every Legion executor (claude/opus/sonnet/haiku, gpt-5.x via codex, Cursor Agent, minimax) emits one **`legion.span.v1`** JSONL record per unit of work to `$LEGION_TELEMETRY_DIR` (default `~/.claude/logs/legion/spans/`). This plugin turns that stream into answers.

## Tools

| Bin | What it does |
|---|---|
| `legion-report [--by executor\|model\|status] [--html]` | Per-group **cost / success-rate / p50-p95 latency** table (TUI or static HTML). The dashboard. |
| `legion-bench run --suite core --repo . [--strict]` | Run the Legion harness benchmark: deterministic trigger eval, routing policy, doctor checks, and fixture-backed task cases for session learning / self-learning memory. Writes artifacts under `$LEGION_BENCH_DIR` or `~/.claude/logs/legion/bench`, emits a `legion-bench` span, and can record failed required cases with `--record-failures`. |
| `legion-bench learning-lift --repo . [--strict]` | Run an isolated before/after self-learning fixture and report Harness Bench-style score lift: percentage-point delta plus relative improvement percentage. Use this to verify the measurement path; broad performance claims still require a larger held-out task corpus. |
| `legion-bench compare\|gate --baseline A --candidate B` | Compare two benchmark run artifacts and gate regressions in pass rate, required cases, trigger misses/collisions, and false success. |
| `legion-trace emit --executor X --model Y --status ok [...]` | Append a validated span (the one emitter the runners/orchestrators use). |
| `legion-trace validate <file\|->` | Assert every line is a valid `legion.span.v1` (exit 1 if not). |
| `legion-otel-export [--file F] [--dry-run]` | Map spans → OTLP/HTTP and POST to `$OTEL_EXPORTER_OTLP_ENDPOINT`; a multi-agent run (shared `trace_id`) becomes one trace tree. No-op until the endpoint is set. |
| `legion-doctor [--repo DIR] [--only CHECK] [--json] [--record-failures]` | Verify the install: plugins load, frontmatter + descriptions valid (no block-scalar blanking), MCP packages resolve, Codex+Cursor bridges accept all servers, schemas valid, codex authed, router reachable. `--json` for machine output; `--record-failures` files defects into self-learning. Exits nonzero on failure — wire into CI. |
| `legion-heal {plan\|run} [--max N] [--dry-run] [--no-pr]` | Auto-heal: `legion-doctor --json` (detect) → `legion-delegate run` (codex fixes in an isolated worktree) → doctor + bats + `legion-delegate review` (gate) → `gh pr create` (**never** auto-merged). Idempotent (one `legion-heal/<check>-<hash>` branch per finding), capped, opt-in in the daily refresh via `LEGION_HEAL=1`. |
| `legion-context-profile {list\|groups\|suggest\|coverage\|apply} [--profile NAME] [--query TEXT] [--include-group G] [--disable-group G] [--dry-run]` | Reversibly shape active Codex/.agents skills and Claude plugins from external context profile/group JSON. Core owns the generic loader/index; legion-code or the target repo owns concrete groups/profiles. `suggest --query` ranks nearby groups for a task. `coverage` verifies that group catalogs cover expected skill dirs and marketplace plugins. Overlay profiles keep broad coding skills active and only disable explicit noisy groups; strict profiles are opt-in. Archives skills under `skills.disabled/<profile>/`; does not delete them. |
| `legion-session-learn --query TERM [--record]` | Mine recent Claude/Codex/Cursor sessions and project memories for gotchas, explicit user corrections, review findings, visual/deploy failures, dead seams, and CI bypass risks. Use when the user asks Legion to learn from past sessions or wants fewer issues to require human observation. `--record` appends candidates to self-learning outcomes. Daily refresh runs this automatically before `legion-self-learn run` unless `LEGION_SESSION_LEARN=0`. |
| `legion-share [next\|gate] [--target T]` | Measure the **codex-vs-Opus work split** (by runs + tokens, per model) vs the target (default 0.5). `legion-share next` → `codex`/`opus`: who should do the next task to converge. `legion-share gate` → a one-line directive, **exit 1 when under target** (consumed by the opus-core balance hook / CI to nudge delegation). Requires Opus to log its own work via `legion-trace emit --executor opus …` so there's a denominator — the opus-core balance hook does this automatically per inline-edit turn. |
| `legion-self-learn run --apply-memory` | Mine spans, review verdicts, trigger evals, benchmark misses, manual bug records, and routing optimizer advice; attach failures to catalog entities (plugin/skill/command/agent/hook/MCP); write durable daily memory, proposals, scorecard metrics, and experiment ledgers. Source mutation is opt-in via `--apply-source`; candidates run isolated and are kept only on measured improvement. |
| `legion-self-learn hints [--entity TYPE:NAME]` | Read the active self-learning memory before changing Legion harness pieces or running workflow commands. |
| `legion-self-learn record --entity TYPE:NAME --summary "..."` | Record a bug or mistake found during a session so the daily loop can turn it into memory/proposals. |

## When Opus should reach for this

- **"What did that cost?" / "which model should I have used?"** → `legion-report` (cost is real per-model, GPT shown next to Claude — see [[project_legion_marketplace]]).
- **Closing the cost-optimization loop** → the report's per-archetype cost/success/latency is the evidence the routing policy is tuned against (improve quality at equal-or-lower cost).
- **Closing the harness-improvement loop** → `legion-self-learn run --apply-memory` is the local, daily loop: failures + findings + trigger misses become entity-scoped hints/proposals for slash commands, agents, skills, hooks, MCPs, and plugins. Use `--apply-source` only when you intentionally want isolated source candidates tested; Legion keeps the best measured scorecard improvement, updates score-visible trigger descriptions/frontmatter when appropriate, and discards or rolls back the rest.
- **Measuring a harness change before/after** → `legion-bench run --suite core --repo . --strict` before and after the change, then `legion-bench compare` and `legion-bench gate`. Use `legion-bench learning-lift --strict` when you specifically need the self-learning before/after percentage. Use `--record-failures` when failed required cases should become self-learning outcomes.
- **"Is Legion working?"** → `legion-doctor`. Run it after install and in CI.
- **"Why is context getting noisy?"** → `legion-context-profile list`, `legion-context-profile groups`, and optionally `legion-context-profile suggest --query "<task>"` first. Run `legion-context-profile coverage` when changing a group catalog. Then run `legion-context-profile apply --profile <name> --dry-run`. Prefer overlay profiles plus `--include-group`/`--disable-group` over hard allowlists.
- **"Learn from the last few sessions"** → `legion-session-learn --query <project> --record`, then `legion-self-learn run --apply-memory` so the findings become active hints. Daily refresh does the broad no-query scan automatically.
- **Debugging a slow/expensive multi-agent run** → `legion-otel-export` into any OTLP collector (Grafana Tempo, Jaeger, Honeycomb) for a trace tree.

## Self-Learning Protocol

Before editing Legion harness docs or using workflow commands/agents heavily, check:

```bash
legion-self-learn hints
```

When a session or review finds a recurring bug in a command, skill, or agent, record it:

```bash
legion-self-learn record --entity command:feature \
  --summary "Feature lane missed the repo-specific release gate" \
  --severity medium --evidence "review finding / PR link / run id"
```

The daily `legion-refresh` cron runs `legion-session-learn --record`, then
`legion-self-learn run --apply-memory --quiet`. This writes
`~/.claude/logs/legion/self-learn/harness-memory.json` and a markdown experiment
log. It does not silently edit vendored or source harness files, and unresolved
outcomes stay active until a kept source experiment resolves them.

## The span contract

`schema/legion.span.v1.schema.json` is the source of truth. Required: `schema, ts, run_id, executor, model, status`. Carries `cost_usd`, `duration_ms`, `tokens`, `trace_id`/`parent_id` (for trace trees), `target_type`/`target_name` (for self-learning attribution), and `artifacts`. `legion-delegate` already emits it; new executors should use `legion-trace emit` so the stream stays uniform.

## Cost

Per-model cost is computed upstream (by the router / `legion-delegate` from `legion-router/config/costs.json`) and carried in each span's `cost_usd`, so this plugin only aggregates — one price table, no divergence.
