---
name: legion-opencode-mode
kind: ability
description: The decision guide for an opencode-primary Legion session. It identifies when a scoped unit of work should go to the configured role for an archetype and when it should stay inline. Use when running Legion under opencode, when a task needs a second opinion, or when the user asks to use Legion on opencode.
---

# Legion — opencode mode

You are **opencode** running a Legion session. You do **most of the work yourself**.
Legion makes every other harness reachable through **one metered command**:

```bash
legion-delegate run --executor <claude|codex|cursor|opencode|deepseek|hermes|pi> --task "…" --repo .
```

Each call runs the target headless and emits a `legion.span.v1` span so the work shows
in the Console with its cost. Codex, Cursor, opencode, and Claude delegation run in
isolated git worktrees and bring back reviewable diffs.
This is the opencode view of the same harness-agnostic `legion-router` policy:
**you** are the active primary and delegate only when the configured archetype
calls for a distinct role.

## Default: do it yourself

opencode is capable. Implement features, write tests, fix bugs, refactor, do bulk edits,
write docs, debug — inline, no delegation. Delegation has overhead; spend it only where a
different model changes the outcome. When available, check prior lessons first:

```bash
legion-self-learn hints --entity skill:legion-opencode-mode
```

## When to delegate — by archetype and role

| Situation | Archetype | Current role | Why |
|---|---|---|---|
| Deep architecture / system design | `architecture-decision` / `deep-reasoning` | `self` | Keep primary-owned judgement with the active harness. |
| Polished / complex frontend | `frontend-polish` | `claude_opus` | Current route for a separate visual/a11y pass. |
| Final adversarial review | `final-review` | `claude_default` | Current independent merge-judgement route. |
| Large, well-specified implementation | `implement-feature` / `bulk-mechanical-edit` | `codex_workhorse` | Current bounded implementation route. |
| Independent second opinion / tie-break | `second-opinion-review` / `cross-model-tiebreak` | `cursor_default` | Current distinct-lineage route. |
| Security review | `security-review` | `codex_review` | Current structured review role. |
| Routine edit with enough context | `self` | `self` | Inline work avoids handoff overhead. |

These are current configuration facts. The role and executor may change with
`models.toml`, `executors.toml`, or `routing.toml`; no harness is the default
secondary by architecture.

## Convergence

For a substantial inline workflow, record each material checkpoint with
`legion-converge --checkpoint <file> --repo . --json`. Continue only when it
returns `actionable` with changed source or failure evidence. Yield on
`complete`, `waiting_external`, or `blocked`; an external state change can
resume `waiting_external`. Never rerun validation on an unchanged tree or
review the same immutable head merely to keep the primary turn alive.

## How to delegate

```bash
# Hand bounded implementation to its configured role:
legion-delegate run --archetype implement-feature --task "Build the export API route per <spec>" --repo . --apply

# Get an independent review of your diff:
legion-delegate run --executor codex --archetype final-review \
  --task "Review the committed diff origin/main...HEAD; report only actionable findings and do not edit files." \
  --base HEAD --repo .

# Frontend polish follows its configured role:
legion-delegate run --archetype frontend-polish --task "Polish the settings page: spacing, a11y, responsive, motion" --repo .

# Fan out several independent slices in parallel (routes each to its best executor):
legion-fanout --slices slices.jsonl --repo . --apply
```

`--executor` names any harness in `legion-route --list-executors`; use it only
when deliberately overriding policy. Omit it to use the archetype's routed
role. `self`-routed
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
