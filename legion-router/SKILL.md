---
name: legion-router
kind: ability
description: Use when Opus should hand a scoped sub-task to an external model (Codex / GPT-5.5 / GPT-5.4 / Cursor Agent) instead of doing it itself — bulk mechanical edits, independent parallel code generation, cross-model review, Cursor second opinions, or tie-breaks. Drives `legion-delegate` for Codex and `legion-cursor` for Cursor Agent, both in isolated worktrees with metered telemetry. Triggers on "delegate to codex/gpt/cursor", "second opinion", "cross-model review", or cost-metered model routing. (For orchestrating a whole multi-step goal across models, use legion-orchestrate.)
---

# Legion Router — delegate to a legion of models

## Work split — balance by strength (target: codex does ≥50%)

Before changing routing behavior or running a high-leverage delegation workflow,
check learned harness guardrails when available:

```bash
legion-self-learn hints --entity plugin:legion-router
```

Legion is a team. Play each model to its strength:

- **Opus = orchestrate** — plan, decompose, decide, **verify**, integrate. Opus is the *conductor*, not the bulk coder. (archetypes: `orchestrate`, `architecture-decision`, `deep-reasoning`)
- **GPT-5.4 = the workhorse** — do **most of the coding**: implement, tests, refactors, bulk edits, migrations, boilerplate. (archetypes: `implement-feature`, `write-tests`, `fix-bug`, `refactor-module`, `bulk-mechanical-edit`, `parallel-codegen`, `cheap-bulk`, `docs-edit`, `boilerplate`, `migration`)
- **GPT-5.5 = the strong one** — **final review** (always get its sign-off before merge) + hard/critical/risky work + cross-model verification. (archetypes: `final-review`, `second-opinion-review`, `cross-model-tiebreak`, `security-review`, `hard-bug`, `perf-optimization`)

**The rule:** codex (5.4 + 5.5) should do **≥50% of delegatable work** (`routing.toml [targets].codex_share`). Concretely — when you have an implementation task, **delegate it to GPT-5.4 by default** rather than coding it yourself; reserve your own cycles for orchestration + judgement, and route the **final review to GPT-5.5**.

**Make it measurable (the controller loop):**
1. When you do a task **yourself**, log it: `legion-trace emit --executor opus --model opus --status ok` (so the split has a denominator).
2. Before doing an eligible implementation task inline, check `legion-share next` — if it says `codex`, **delegate it** (you're under target); if `opus`, your call.
3. `legion-share` shows the live ratio + per-model breakdown vs the 0.5 target.

So: **Delegate any task that's independent and self-contained** — cheaper/faster on GPT-5.4, benefits from GPT-5.5's perspective, or parallelizable so Opus stays free to coordinate. Keep only orchestration + genuine judgement inline.

## The honest mechanism

`codex exec` is an **autonomous agent** (task → edits), not a chat endpoint. So GPT work does **not** flow through the :8082 HTTP proxy — it runs out-of-band via `legion-delegate`, which:

1. creates an **isolated git worktree** (no contamination of your tree),
2. runs `codex exec -m <model> -s <sandbox>` with the task piped via **stdin** (injection-safe),
3. captures the **diff** + last message + **token usage**,
4. prices it via the shared cost table and emits a `legion.span.v1` **telemetry span**,
5. best-effort POSTs usage to the router **/ingest** sink so GPT cost shows next to Claude.

You then **verify the diff** before applying it. Delegation never auto-applies unless you pass `--apply` and the verify gate is clean.

Cursor Agent uses the same sidecar pattern through `legion-cursor`: it runs Cursor's headless `agent -p --trust` in an isolated worktree, maps `--sandbox read-only` to Cursor plan mode, captures the diff/result, emits `executor:"cursor"` telemetry with the actual returned model when Cursor reports one, and leaves applying the patch to the orchestrator unless `--apply` is passed.

## When to delegate (decision guide)

| Situation | Delegate? | How |
|---|---|---|
| Bulk mechanical edit across many files | ✅ yes | `run --model gpt-5.5 --sandbox workspace-write` |
| Independent module/file you can spec fully | ✅ yes | `run` with a tight, stateless task description |
| Second opinion on a risky diff / PR | ✅ yes | `review --model gpt-5.5 --base <branch>` |
| Two designs both plausible (tie-break) | ✅ yes | `review` on each, compare verdicts |
| Task needs your conversation context / judgement | ❌ no | do it inline |
| Tiny edit you can do in one tool call | ❌ no | do it inline (delegation overhead isn't worth it) |
| Anything touching secrets / untrusted input with write access | ⚠️ caution | read-only sandbox, or refuse |

## Scoping a stateless task

The delegated agent starts fresh — **no access to this conversation**. Write the task as if briefing a new engineer: name the files, state the exact change, give the acceptance criteria, and say "make the minimal edit, no unrelated changes."

## Let Legion pick the model — `--archetype`

Prefer `--archetype` over a raw `--model`: the routing policy (`config/routing.toml`, resolved by `legion-route`) picks the **cheapest model that clears the bar** plus the right sandbox and reasoning effort. Run `legion-route --list` for the current set:

Run `legion-route --list` for the full set. Grouped by role:

| Role | Archetypes | → model |
|---|---|---|
| **Opus orchestrates (self)** | `orchestrate`, `architecture-decision`, `deep-reasoning` | opus — **refuses to delegate** |
| **GPT-5.4 workhorse (most coding)** | `implement-feature`, `write-tests`, `fix-bug`, `refactor-module`, `bulk-mechanical-edit`, `parallel-codegen`, `cheap-bulk`, `docs-edit`, `boilerplate`, `migration` | gpt-5.4 (fallback gpt-5.5) |
| **GPT-5.5 strong (review + hard)** | `final-review`, `second-opinion-review`, `cross-model-tiebreak`, `security-review`, `hard-bug`, `perf-optimization` | gpt-5.5 |

So: most coding → GPT-5.4; final review + hard/critical → GPT-5.5; orchestration + judgement → you keep it (delegating it is refused).

## Commands

```bash
# Auto-routed delegation (model/sandbox/effort from routing.toml):
legion-delegate run --archetype bulk-mechanical-edit \
  --task "In src/foo.ts add a null-guard to bar(); minimal edit only" --repo .

# Cursor Agent second implementation / editor-native opinion:
legion-cursor run --task "Try the same fix using Cursor Agent; minimal edit only" --repo .

# Pin a model/effort explicitly (overrides the archetype):
printf '%s' "$LONG_TASK" | legion-delegate run --model gpt-5.5 --reasoning-effort high --repo .

# Cross-model second opinion → STRUCTURED verdict JSON you can reconcile:
legion-delegate review --archetype second-opinion-review --base main --repo .
#   -> {verdict: approve|request_changes|comment, summary, findings:[{severity,title,file,line,detail}]}

# Iterate on a kept session (same codex thread) instead of starting fresh:
legion-delegate run    --archetype parallel-codegen --task "..." --repo . --keep   # note the run_id
legion-delegate resume --run <RUN_ID> --task "now also handle the empty case" --repo .

# Apply a verified diff, then clean up:
legion-delegate apply   --run <RUN_ID> --repo .
legion-delegate cleanup --run <RUN_ID> --repo .
```

Reasoning effort (via codex `-c model_reasoning_effort`): **codex always runs at `xhigh`** — every archetype is xhigh and `legion-delegate` defaults to xhigh when unset (on a subscription the marginal cost is flat, so favor quality). Opus orchestrates at **xhigh minimum** (dynamic higher if a task needs it). `review` returns a schema-valid verdict (`schema/review-verdict.schema.json`) so you can weigh GPT's findings against your own programmatically.

## Credit / quota resilience (self-healing)

- **Auto-fallback:** if the chosen model hits a quota/rate-limit error, `run` automatically walks the archetype's `fallback` chain (e.g. `gpt-5.4` → `gpt-5.5`) and retries; a *non*-quota failure stops immediately (doesn't burn the chain).
- **Low-credit mode:** set `LEGION_LOW_CREDIT` to steer away from a depleted provider:
  - `LEGION_LOW_CREDIT=claude` → Claude is low: delegate *more* to GPT (even normally-self tasks route to GPT-5.5).
  - `LEGION_LOW_CREDIT=codex` (or `gpt`) → GPT is low: **refuse to delegate**, so Opus does it inline instead (`LEGION_FORCE_DELEGATE=1` overrides if you want to spend the last credits anyway).
- **Budget is advisory:** `--budget-tokens N` flags an over-budget run (`status: over_budget`) but still returns the usable diff and **exits 0** — codex can't be pre-empted mid-run, so budget never silently fails a good result.

## Worktree lifecycle

- `run` **auto-deletes** its worktree + branch on completion (artifacts under `runs/` are preserved). Pass `--keep` to retain it (required to `resume`).
- Bulk cleanup when you need it: `legion-delegate cleanup --all` (all worktrees + branches), add `--purge` to also drop `runs/` artifacts; or `cleanup --run <RUN_ID> [--purge]` for one.

## Verify the returned diff (always)

Read `diff_path`, sanity-check it does exactly what you asked and nothing else, then run the repo's typecheck/tests before `apply`. Treat a delegated diff like a PR from an unfamiliar contributor.

## Safety defaults

- `run` defaults to `workspace-write` (edits the worktree); `review` is `read-only`.
- `danger-full-access` is **hard-blocked** unless `LEGION_ALLOW_DANGER=1`.
- Task text is scanned for dangerous/injection patterns before any write run (override: `LEGION_ALLOW_UNSAFE=1`).

> **The sandbox is the security boundary — not the task scanner.** `scan_task_text`
> is a best-effort tripwire and is trivially bypassable (encodings, indirection);
> never treat a passed scan as proof a task is safe. Real containment is the codex
> `--sandbox` plus the isolated git worktree: a `workspace-write` run can still
> modify any file *inside that worktree* (including repo dotfiles like `.zshenv`
> if they exist there). For anything touching secrets or untrusted input, use a
> `read-only` sandbox or refuse — do not rely on the scanner.

## Cost note

GPT-5.x via Codex uses ChatGPT-subscription auth, which reports token counts but **no per-token price** — so GPT cost defaults to `$0` (token-count parity, not dollar). Set real prices in `config/costs.json` (or `LEGION_COSTS_FILE`) if you have API billing.

## Routing proxy (optional, opt-in)

The bundled `:8082` proxy meters Claude/MiniMax traffic translation-free (base-URL+auth swap). It is **opt-in** — only traffic you explicitly point at it via `ANTHROPIC_BASE_URL` is routed; your main session is never forced through it. See `references/routing-policy.md`.
