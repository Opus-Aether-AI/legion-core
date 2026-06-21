---
name: legion-codex-mode
kind: ability
description: The routing brain for a Codex-CLI-primary Legion session — you are GPT-5.5 doing most of the work, and this tells you WHEN to call Claude (via `legion-claude`) instead of doing it yourself, and how Legion's MCPs/skills/bridged-commands work on Codex. Use when running Legion under Codex CLI, when a task smells like deep architecture / polished frontend / final cross-model review, when you're stuck after a couple attempts, or when the user says "ask claude", "get claude to", "second opinion from claude", or "use legion on codex". The mirror image of legion-router (which is the Claude-primary brain).
---

# Legion — Codex mode (you are the primary, Claude is on call)

You are **Codex (GPT-5.5)** running a Legion session. You do **most of the work yourself**.
Legion gives you one extra lever: when a task is genuinely better on Claude, hand it up
with **`legion-claude`** — metered, and with **automatic GPT-5.5 fallback if the Claude
limit is hit**, so reaching for Claude never blocks you.

This is the mirror of `legion-router` (the Claude-primary brain). There, Opus orchestrates
and delegates *down* to GPT. Here, **you** orchestrate and delegate *up* to Claude — only
for the few archetypes where it clearly wins.

## Default: do it yourself

Before working on Legion harness behavior or delegating a risky task, check the
local self-learning memory when available:

```bash
legion-self-learn hints --entity skill:legion-codex-mode
```

GPT-5.5 is strong. Implement features, write tests, fix bugs, refactor, do bulk edits,
write docs, debug — all inline, no delegation. Delegation has overhead; spend it only
where Claude's strength changes the outcome.

## When to call Claude (`legion-claude run`)

| Situation | Call Claude? | Why |
|---|---|---|
| Deep architecture / system design with many tradeoffs | ✅ yes | Opus is the strongest reasoner for open-ended design |
| **Polished / complex frontend** (UX, a11y, responsive, design-system) | ✅ yes | **Opus + the `impeccable` skill is the best frontend combo** — reach for it on anything user-facing and visual |
| Final adversarial review of your own diff before merge | ✅ yes | cross-model verification catches what your own lens misses |
| You're stuck / uncertain after ~2 honest attempts | ✅ yes | a fresh, stronger perspective beats grinding |
| Tie-break between two plausible designs | ✅ yes | an independent judge breaks the symmetry |
| Routine implement / test / refactor / bulk edit | ❌ no | you've got it — inline |
| Tiny one-tool-call edit | ❌ no | overhead isn't worth it |

Rule of thumb: **delegate up for judgement, design, polish, and verification — not for volume.**

## How to call Claude

```bash
# Hand a scoped task to Claude; metered; auto-falls back to GPT-5.5 on Claude limit.
legion-claude run --task "Design the module boundary for X: options, tradeoffs, a recommendation" --repo .

# Force a specific Claude model (default is the strongest available):
legion-claude run --task "..." --model claude-opus-4-8 --repo .

# Frontend polish with Opus + impeccable (describe the surface + the bar):
legion-claude run --task "Polish the settings page: spacing, a11y, responsive, motion — impeccable pass" --repo .

# If you'd rather be blocked than silently fall back to GPT:
legion-claude run --task "..." --no-fallback           # -> status: blocked (no GPT fallback)

# Read the task from stdin (for long/multi-line briefs):
printf '%s' "$LONG_BRIEF" | legion-claude run --repo .
```

`legion-claude` runs `claude -p` headless, returns Claude's result + a `legion.span.v1`
span (so the work shows in the dashboard with cost), and **on a usage-limit / unavailable
error it automatically completes the task on GPT-5.5** and reports `fell_back: true` with
the reason. You stay productive whether or not Claude has headroom.

## Scope it like a brief to a fresh engineer

Claude starts with **no access to your Codex conversation**. Name the files, state the
exact change or question, give acceptance criteria, and say "minimal change, nothing
unrelated." Then **verify what comes back** before applying — treat it like a PR from a
strong but unfamiliar contributor.

## Credit-aware

You're on Codex because you're conserving Claude. So:

- Default to doing the work yourself; call Claude for the high-leverage cases above.
- `LEGION_LOW_CREDIT=claude` makes `legion-claude` **skip Claude entirely** and go straight
  to GPT-5.5 — set it when you know your Claude limit is spent and don't want the round-trip.
- Every `legion-claude` call is metered into the same telemetry as the rest of Legion, so
  the Console shows exactly how much Claude you've used.

## What works natively on Codex (so you don't reach for Claude needlessly)

Legion is wired into Codex by `legion-setup codex` (run it once / on update):

- **MCPs** — `context7` (live library docs), `playwright` (browser), `codebase-memory`
  (semantic code memory) are registered in `~/.codex/config.toml`. Use them directly.
- **Skills** — the whole marketplace skill set is mirrored to `~/.codex/skills`.
- **Bridged commands & agents** — Claude's slash commands and subagents have **no native
  Codex form**, so they're bridged to skills: `legion-cmd-<name>` (e.g. `legion-cmd-feature`,
  `legion-cmd-review-gate`) and `legion-agent-<name>`. Their guidance triggers when you
  describe the matching task — you don't type a slash command.

So most capability is already at your fingertips on Codex. Save `legion-claude` for the
judgement / design / polish / final-review calls where Opus genuinely changes the result.

## One-time wiring

```bash
legion-setup codex          # register MCPs + mirror skills + bridge commands/agents + verify
legion-setup codex verify   # read-only readiness check
```
