---
name: legion-codex-mode
kind: ability
description: The routing guide for a Codex-primary Legion session. It explains when to retain work inline, when to use the configured role for an archetype, and how Legion's MCPs, skills, and bridged commands work on Codex. Use when running Legion under Codex CLI, when work needs architecture judgement, polished frontend, or independent review, or when the user asks for Legion on Codex.
---

# Legion — Codex mode

You are **Codex**, the active primary for this session. Keep work inline when
you have the necessary context. When a scoped task benefits from a different
perspective or capability, route it through the configured archetype. The
secondary is the role configured for that archetype, not a fixed on-call
harness.

`legion-router` is the shared, harness-agnostic router. Every primary mode uses
the same registry, routing policy, worktree, evidence, and review contracts.

## Default: do it yourself

Before working on Legion harness behavior or delegating a risky task, check the
local self-learning memory when available:

```bash
legion-self-learn hints --entity skill:legion-codex-mode
```

Implement features, write tests, fix bugs, refactor, do bulk edits, write docs,
and debug inline when that is the best fit. Delegation has overhead; use it
when the configured role changes the outcome.

## Choose the configured role

| Need | Archetype | Current role | Decision |
|---|---|---|---|
| Architecture or high-judgement decision | `architecture-decision` / `deep-reasoning` | `self` | Keep it with the active primary. |
| Polished frontend pass | `frontend-polish` | `claude_opus` | Delegate only when the visual/a11y pass is worth a separate worker. |
| Final merge judgement | `final-review` | `claude_default` | Use the configured independent review role. |
| Security review or hard bug | `security-review` / `hard-bug` | `codex_review` | Use the configured Codex review role. |
| Different-lineage opinion | `second-opinion-review` | `cursor_default` | Use when an independent lens matters. |
| Bounded implementation | `implement-feature` / `fix-bug` | `codex_workhorse` | Keep inline when you already have the context; otherwise use the route. |

These are current routing facts from `routing.toml` and `models.toml`, not a
claim that any harness is structurally primary or secondary. Inspect them with
`legion-route --list` before relying on a deployment-specific route.

## How to delegate

```bash
# Let policy choose the executor and role for a bounded implementation.
legion-delegate run --archetype implement-feature --task "Build the export API route per <spec>" --repo . --apply

# Ask for the current frontend-polish role without encoding a harness assumption.
legion-delegate run --archetype frontend-polish --task "Polish the settings page: spacing, a11y, responsive, motion" --repo .

# Obtain the current final-review role's verdict for an immutable diff.
legion-delegate review --archetype final-review --base origin/main --head HEAD --repo .
```

Use `legion-delegate run --executor <name>` only when deliberately overriding
policy. The executor list is discoverable with `legion-route --list-executors`.

## Scope it like a brief to a fresh engineer

The delegated worker starts with **no access to your Codex conversation**. Name
the files, state the exact change or question, give acceptance criteria, and say
"minimal change, nothing unrelated." Then **verify what comes back** before
applying — treat it like a PR from a strong but unfamiliar contributor.

## Credit-aware

- Default to doing the work yourself; delegate only for a high-leverage route.
- `LEGION_LOW_CREDIT=<executor>` steers routing away from a depleted provider.
- Delegation records a span using the executor's published usage contract. A
  zero usage value can mean "not reported" for an executor without one.

## What works natively on Codex

Legion is wired into Codex by `legion-setup codex` (run it once / on update):

- **MCPs** — `context7` (live library docs), `playwright` (browser), `codebase-memory`
  (semantic code memory) are registered in `~/.codex/config.toml`. Use them directly.
- **Skills** — the whole marketplace skill set is mirrored to `~/.codex/skills`.
- **Bridged commands & agents** — Claude's slash commands and subagents have **no native
  Codex form**, so they're bridged to skills: `legion-cmd-<name>` (e.g. `legion-cmd-feature`,
  `legion-cmd-review-gate`) and `legion-agent-<name>`. Their guidance triggers when you
  describe the matching task — you don't type a slash command.

Most capability is already available in Codex. Use the routing policy whenever
an archetype needs a distinct configured role.

## One-time wiring

```bash
legion-setup codex          # register MCPs + mirror skills + bridge commands/agents + verify
legion-setup codex verify   # read-only readiness check
```

## Convergence

For a substantial inline workflow, record each material checkpoint with
`legion-converge --checkpoint <file> --repo . --json`. Continue only when it
returns `actionable` with changed source or failure evidence. Yield on
`complete`, `waiting_external`, or `blocked`; an external state change can
resume `waiting_external`. Never rerun validation on an unchanged tree or
review the same immutable head merely to keep the primary turn alive.
