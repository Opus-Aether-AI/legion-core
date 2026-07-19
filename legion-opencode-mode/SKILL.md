---
name: legion-opencode-mode
kind: ability
description: The decision guide for an opencode-primary Legion session — you are opencode doing most of the work yourself, and this tells you WHICH kind of task is worth handing to another model and to WHOM (Claude for deep architecture and polished frontend with the impeccable skill, a workhorse model for bulk implementation, a different model for a second opinion) versus keeping it inline. Use when running Legion under opencode, when a task smells like deep architecture / polished frontend / final cross-model review, when you're stuck after a couple attempts, or when the user says "ask claude", "get a second opinion", or "use legion on opencode". The opencode counterpart of legion-codex-mode.
---

# Legion — opencode mode (you are the primary; the other harnesses are on call)

You are **opencode** running a Legion session. You do **most of the work yourself**.
Legion makes every other harness reachable through **one metered command**:

```bash
legion-delegate run --executor <claude|codex|cursor> --task "…" --repo .
```

Each call runs the target headless and emits a `legion.span.v1` span so the work shows
in the Console with its cost. Diff-producing executors (codex/cursor/opencode) run in an
isolated git worktree and bring back a reviewable diff; Claude (a prompt executor) runs
in-place and returns a result.
This is the opencode mirror of `legion-codex-mode` (Codex-primary) and `legion-router`
(Claude-primary): **you** orchestrate and delegate *out* — only for the archetypes where
another model clearly wins.

## Default: do it yourself

opencode is capable. Implement features, write tests, fix bugs, refactor, do bulk edits,
write docs, debug — inline, no delegation. Delegation has overhead; spend it only where a
different model changes the outcome. When available, check prior lessons first:

```bash
legion-self-learn hints --entity skill:legion-opencode-mode
```

## When to delegate — and to whom

| Situation | Delegate to | Why |
|---|---|---|
| Deep architecture / system design with many tradeoffs | `claude` | strongest open-ended reasoner |
| **Polished / complex frontend** (UX, a11y, responsive, design system) | `claude` | Opus + the `impeccable` skill is the best frontend combo |
| Final adversarial review of your own diff before merge | `codex` (or `claude`) | cross-model verification catches your blind spots |
| Large, well-specced bulk implementation / mechanical edits | `codex` | throughput at flat subscription cost |
| Independent second opinion / tie-break | `cursor` or `claude` | a different lens breaks the symmetry |
| Routine implement / test / refactor / small edit | — (inline) | you've got it; overhead isn't worth it |

Rule of thumb: **delegate for judgement, design, polish, verification, and bulk volume — not for the everyday.**

## How to delegate

```bash
# Ask Claude for a design/architecture decision (metered):
legion-delegate run --executor claude --task "Design the module boundary for X: options, tradeoffs, a recommendation" --repo .

# Hand bulk implementation to Codex:
legion-delegate run --executor codex --archetype implement-feature --task "Build the export API route per <spec>" --repo . --apply

# Get an independent review of your diff:
legion-delegate run --executor codex --archetype final-review --base HEAD --repo .

# Frontend polish with Opus + impeccable (describe the surface + the bar):
legion-delegate run --executor claude --task "Polish the settings page: spacing, a11y, responsive, motion — impeccable pass" --repo .

# Fan out several independent slices in parallel (routes each to its best executor):
legion-fanout --slices slices.jsonl --repo . --apply
```

`--executor` names any harness in `legion-route --list-executors`. Omit it to use the
archetype's routed executor (Codex by default for coding archetypes). `self`-routed
archetypes (orchestrate / architecture-decision / deep-reasoning / frontend-implement) mean
**you** handle them inline — that's you, the primary.

## Scope it like a brief to a fresh engineer

The delegate starts with **no access to your opencode conversation**. Name the files, state
the exact change or question, give acceptance criteria, and say "minimal change, nothing
unrelated." Then **verify what comes back** before applying — treat it like a PR from a
strong but unfamiliar contributor.

## Credit-aware

- Default to doing the work yourself; delegate for the high-leverage cases above.
- `LEGION_LOW_CREDIT=<executor>` steers away from a depleted provider.
- Every delegation is metered into the same telemetry as the rest of Legion, so
  `legion-share` and the Console show the exact work split.

## One-time wiring

```bash
legion-setup opencode          # register Legion MCPs into opencode + wire delegation on PATH + verify
legion-setup opencode verify   # read-only readiness check
```

opencode already reads the shared Legion skills from `~/.agents/skills`, and every
`legion-*` CLI is on your PATH, so most capability is at your fingertips. Save delegation
for the judgement / design / polish / final-review / bulk calls where another model wins.
