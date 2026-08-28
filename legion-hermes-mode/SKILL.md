---
name: legion-hermes-mode
kind: ability
description: The routing guide for a Hermes-primary Legion session. Use when Hermes is driving work, when deciding whether a bounded unit should stay inline or use a different executor, when a cron or skill hands work to Hermes, or when the user asks to use Legion from Hermes, get a second opinion, review a Hermes change, or delegate from Hermes.
---

# Legion — Hermes mode

## Convergence

For a substantial inline workflow, record each material checkpoint with
`legion-converge --checkpoint <file> --repo . --json`. Continue only when it
returns `actionable` with changed source or failure evidence. Yield on
`complete`, `waiting_external`, or `blocked`; an external state change can
resume `waiting_external`. Never rerun validation on an unchanged tree or
review the same immutable head merely to keep the primary turn alive.

You are **Hermes**, the active Legion primary and a registered executor. Keep
bounded work inline when you have the right context. For independent implementation,
review, or a second perspective, make one explicit handoff through Legion so it is
isolated and metered (`legion.span.v1`), rather than an untracked raw provider call.

This is one of the primary-mode skills: you orchestrate and can code; Legion
gives every registered family the same bounded cross-harness handoff contract.

## The rule: delegate coding through Legion, never raw

From your `terminal` / `process` tool, use the Legion CLIs on PATH:

```bash
# One scoped task -> the configured role, metered, isolated worktree:
legion-delegate run --archetype implement-feature --task "Build X per <spec>" --repo /path/to/repo --apply

# Force a specific different harness only when deliberately overriding policy:
legion-delegate run --executor codex --task "Fix the flaky retry in <file>" --repo /path/to/repo --apply

# Independent review of a committed diff before you act on it:
legion-delegate run --executor codex --archetype final-review \
  --task "Review the committed diff origin/main...HEAD; report only actionable findings and do not edit files." \
  --base HEAD --repo /path/to/repo

# Several independent slices in parallel, each routed to its best model:
legion-fanout --slices /tmp/slices.jsonl --repo /path/to/repo --apply

# A whole heavy task with plan + gates + evidence + learning + heal:
legion-run --repo /path/to/repo --task "Add org invitations with tests and review" \
  --plan-file plan.md --validate-command "npm test && npm run build" --json
```

Do not bypass Legion with `claude --print …`, `codex exec …`, or `opencode run …`
— those bypass routing, metering, worktree isolation, and the review gate. If you already
have a script or cron that shells out raw (e.g. the coco implementation cron), switch it to
`legion-delegate run` / `legion-claude run` so the work is metered and inspectable.

## When to keep work or delegate

| Need | Archetype | Current role | Why |
|---|---|---|---|
| Bounded implementation with enough context | `self` | `self` | Hermes can complete it inline as the active primary. |
| Bulk implementation / mechanical edits / boilerplate | `implement-feature` / `bulk-mechanical-edit` | `codex_workhorse` | Current bounded implementation route. |
| Deep architecture / system design / hard tradeoffs | `architecture-decision` / `deep-reasoning` | `self` | Keep primary-owned judgement inline. |
| Polished / complex frontend | `frontend-polish` | `claude_opus` | Current separate visual/a11y route. |
| Final adversarial review | `final-review` | `claude_default` | Current independent merge-judgement route. |
| Different-lineage opinion | `second-opinion-review` | `cursor_default` | Current independent perspective route. |
| Security review | `security-review` | `codex_review` | Current structured review role. |

These are current registry and routing facts, not a fixed hierarchy among
harnesses. Omit `--executor` to accept the configured archetype route (see
`legion-route --list`).
List the executors with `legion-route --list-executors`. A delegated worker may
handoff only once to a **different** family; same-family recursion and depth
overflow fail closed.

## Verify before you act

A delegate starts with **no access to your hermes context**. Give it a self-contained
brief: name the files, the exact change, acceptance criteria, "minimal change only." Then
**read the returned diff/result before applying or reporting to the user** — treat it like a
PR from a strong but unfamiliar contributor. `--apply` lands the diff; omit it to inspect
`diff_path` first.

## It's all metered

Every `legion-delegate` / `legion-fanout` / `legion-run` call emits telemetry, so:

- `legion-share` shows the configured work split,
- `legion-report` / the Console show cost, latency, and per-model breakdown,
- runs land under your Legion state root (harness-neutral; no writes into `~/.claude`).

Set `LEGION_PRIMARY=hermes` in the environment your delegations run in so Legion attributes
the orchestration to you. Run `legion-setup hermes` once to create the managed
native discovery link, then `legion-setup hermes verify` to check that skill,
adapter, provider CLI, and executor registry without changing configuration.
