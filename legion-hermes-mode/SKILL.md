---
name: legion-hermes-mode
kind: ability
description: The routing guide for a Hermes-primary Legion session. Use when Hermes is driving coding work, when deciding whether a bounded task should stay inline or use a different coding harness, when a cron or skill hands code work to Hermes, or when the user asks to use Legion from Hermes, get a second opinion, review a Hermes change, or delegate from Hermes.
---

# Legion — Hermes mode

## Convergence

For a substantial inline workflow, record each material checkpoint with
`legion-converge --checkpoint <file> --repo . --json`. Continue only when it
returns `actionable` with changed source or failure evidence. Yield on
`complete`, `waiting_external`, or `blocked`; an external state change can
resume `waiting_external`. Never rerun validation on an unchanged tree or
review the same immutable head merely to keep the primary turn alive.

You are **Hermes**, the active Legion primary and a registered coding family. Keep
bounded work inline when you have the right context. For independent implementation,
review, or a second perspective, make one explicit handoff through Legion so it is
isolated and metered (`legion.span.v1`), rather than an untracked raw provider call.

This is the Hermes counterpart of the Codex, opencode, and Pi primary-mode skills:
you orchestrate and can code; Legion gives every registered family the same bounded
cross-harness handoff contract.

## The rule: delegate coding through Legion, never raw

From your `terminal` / `process` tool, use the Legion CLIs on PATH:

```bash
# One scoped coding task -> the routed executor (Codex by default), metered, isolated worktree:
legion-delegate run --archetype implement-feature --task "Build X per <spec>" --repo /path/to/repo --apply

# Force a specific different harness (symmetric — any registered family):
legion-delegate run --executor claude --task "Design the data model for X: tradeoffs + a recommendation" --repo /path/to/repo
legion-delegate run --executor codex  --archetype fix-bug --task "Fix the flaky retry in <file>" --repo /path/to/repo --apply
legion-delegate run --executor pi --task "Independently review this bounded change" --repo /path/to/repo

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

| Need | Executor | Why |
|---|---|---|
| Bounded implementation with enough context | `self` | Hermes can complete it inline as the active primary |
| Bulk implementation / mechanical edits / boilerplate | `codex` (default) | throughput at flat subscription cost |
| Deep architecture / system design / hard tradeoffs | `claude` | strongest open-ended reasoner |
| Polished / complex frontend (UX, a11y, responsive) | `claude` | Opus + the `impeccable` skill |
| Final adversarial review before you act | `codex` or `claude` | cross-model verification |
| Cheap/experimental delegation | `opencode` (minimax) | low-cost open harness |

Omit `--executor` to accept the archetype's default route (see `legion-route --list`).
List the harnesses with `legion-route --list-executors`. A delegated worker may
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

- `legion-share` shows the codex-vs-primary work split,
- `legion-report` / the Console show cost, latency, and per-model breakdown,
- runs land under your Legion state root (harness-neutral; no writes into `~/.claude`).

Set `LEGION_PRIMARY=hermes` in the environment your delegations run in so Legion attributes
the orchestration to you. Run `legion-setup hermes` once to create the managed
native discovery link, then `legion-setup hermes verify` to check that skill,
adapter, provider CLI, and executor registry without changing configuration.
