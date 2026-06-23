---
name: legion-observability
kind: ability
description: Use for "how much did that cost", "which model is winning", or "is legion set up right" — Legion telemetry, `legion.span.v1` traces, doctor, heal, and self-learn answers.
---

# Legion Observability — see everything

Every Legion executor (claude/opus/sonnet/haiku, gpt-5.x via codex, Cursor Agent, minimax) emits one **`legion.span.v1`** JSONL record per unit of work to `$LEGION_TELEMETRY_DIR` (default `~/.claude/logs/legion/spans/`). This plugin turns that stream into answers.

## Tools

| Bin | What it does |
|---|---|
| `legion-report [--by executor\|model\|status] [--html]` | Per-group **cost / success-rate / p50-p95 latency** table (TUI or static HTML). The dashboard. |
| `legion-trace emit --executor X --model Y --status ok [...]` | Append a validated span (the one emitter the runners/orchestrators use). |
| `legion-trace validate <file\|->` | Assert every line is a valid `legion.span.v1` (exit 1 if not). |
| `legion-otel-export [--file F] [--dry-run]` | Map spans → OTLP/HTTP and POST to `$OTEL_EXPORTER_OTLP_ENDPOINT`; a multi-agent run (shared `trace_id`) becomes one trace tree. No-op until the endpoint is set. |
| `legion-doctor [--repo DIR] [--only CHECK] [--json] [--record-failures]` | Verify the install: plugins load, frontmatter + descriptions valid (no block-scalar blanking), MCP packages resolve, Codex+Cursor bridges accept all servers, schemas valid, codex authed, router reachable. `--json` for machine output; `--record-failures` files defects into self-learning. Exits nonzero on failure — wire into CI. |
| `legion-heal {plan\|run} [--max N] [--dry-run] [--no-pr]` | Auto-heal: `legion-doctor --json` (detect) → `legion-delegate run` (codex fixes in an isolated worktree) → doctor + bats + `legion-delegate review` (gate) → `gh pr create` (**never** auto-merged). Idempotent (one `legion-heal/<check>-<hash>` branch per finding), capped, opt-in in the daily refresh via `LEGION_HEAL=1`. |
| `legion-context-profile apply [--profile webapp-legion] [--dry-run]` | Reversibly trim active Codex/.agents skills and Claude plugins to a repo profile. Use when skill descriptions are shortened, context budget is noisy, or too many irrelevant skills/plugins are loaded. Archives skills under `skills.disabled/<profile>/`; does not delete them. |
| `legion-session-learn --query TERM [--record]` | Mine recent Claude/Codex/Cursor sessions and project memories for gotchas, review findings, visual/deploy failures, dead seams, and CI bypass risks. Use when the user asks Legion to learn from past sessions or wants fewer issues to require human observation. `--record` appends candidates to self-learning outcomes. |
| `legion-share [next\|gate] [--target T]` | Measure the **codex-vs-Opus work split** (by runs + tokens, per model) vs the target (default 0.5). `legion-share next` → `codex`/`opus`: who should do the next task to converge. `legion-share gate` → a one-line directive, **exit 1 when under target** (consumed by the opus-core balance hook / CI to nudge delegation). Requires Opus to log its own work via `legion-trace emit --executor opus …` so there's a denominator — the opus-core balance hook does this automatically per inline-edit turn. |
| `legion-self-learn run --apply-memory` | Mine spans, review verdicts, trigger evals, manual bug records, and routing optimizer advice; attach failures to catalog entities (plugin/skill/command/agent/hook/MCP); write durable daily memory, proposals, scorecard metrics, and experiment ledgers. Source mutation is opt-in via `--apply-source`; candidates run isolated and are kept only on measured improvement. |
| `legion-self-learn hints [--entity TYPE:NAME]` | Read the active self-learning memory before changing Legion harness pieces or running workflow commands. |
| `legion-self-learn record --entity TYPE:NAME --summary "..."` | Record a bug or mistake found during a session so the daily loop can turn it into memory/proposals. |

## When Opus should reach for this

- **"What did that cost?" / "which model should I have used?"** → `legion-report` (cost is real per-model, GPT shown next to Claude — see [[project_legion_marketplace]]).
- **Closing the cost-optimization loop** → the report's per-archetype cost/success/latency is the evidence the routing policy is tuned against (improve quality at equal-or-lower cost).
- **Closing the harness-improvement loop** → `legion-self-learn run --apply-memory` is the local, daily loop: failures + findings + trigger misses become entity-scoped hints/proposals for slash commands, agents, skills, hooks, MCPs, and plugins. Use `--apply-source` only when you intentionally want isolated source candidates tested; Legion keeps the best measured scorecard improvement, updates score-visible trigger descriptions/frontmatter when appropriate, and discards or rolls back the rest.
- **"Is Legion working?"** → `legion-doctor`. Run it after install and in CI.
- **"Why is context getting noisy?"** → `legion-context-profile apply --dry-run` first, then apply the matching repo profile if too many active skills/plugins are loaded.
- **"Learn from the last few sessions"** → `legion-session-learn --query <project> --record`, then `legion-self-learn run --apply-memory` so the findings become active hints.
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

The daily `legion-refresh` cron runs `legion-self-learn run --apply-memory --quiet`.
This writes `~/.claude/logs/legion/self-learn/harness-memory.json` and a markdown
experiment log. It does not silently edit vendored or source harness files, and
unresolved outcomes stay active until a kept source experiment resolves them.

## The span contract

`schema/legion.span.v1.schema.json` is the source of truth. Required: `schema, ts, run_id, executor, model, status`. Carries `cost_usd`, `duration_ms`, `tokens`, `trace_id`/`parent_id` (for trace trees), `target_type`/`target_name` (for self-learning attribution), and `artifacts`. `legion-delegate` already emits it; new executors should use `legion-trace emit` so the stream stays uniform.

## Cost

Per-model cost is computed upstream (by the router / `legion-delegate` from `legion-router/config/costs.json`) and carried in each span's `cost_usd`, so this plugin only aggregates — one price table, no divergence.
