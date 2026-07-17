---
name: legion-hermes-mode
kind: ability
description: The metered-delegation guide for a hermes-primary Legion session — hermes is a long-running persona / messaging assistant / orchestrator (not a coding CLI), and this tells you to hand real coding work to a headless coding harness through METERED Legion CLIs (`legion-delegate run --executor …`, `legion-fanout`, `legion-run`) from your terminal tool, instead of a raw shell-out that leaves no telemetry. Use when hermes needs to implement, edit, test, refactor, or review code, when a cron job or skill hands coding work to a model, or when the user says "have hermes build/fix X" or "use legion from hermes".
---

# Legion — hermes mode (you are a metered primary orchestrator)

You are **hermes**, a long-running assistant/persona — **not** a headless coding CLI. When
a task needs real code written, edited, tested, reviewed, or refactored, you **delegate it
to a coding harness**, and you do that through Legion so every delegation is **metered**
(a `legion.span.v1` span with cost/latency/model) and shows up alongside the rest of your
work — instead of a raw `claude --print` or `codex exec` that vanishes off-book.

This is the hermes mirror of `legion-codex-mode` and `legion-router`: **you orchestrate**;
Legion routes the actual coding to the right model and brings back a verified, metered diff.

## The rule: delegate coding through Legion, never raw

From your `terminal` / `process` tool, use the Legion CLIs on PATH:

```bash
# One scoped coding task -> the routed executor (Codex by default), metered, isolated worktree:
legion-delegate run --archetype implement-feature --task "Build X per <spec>" --repo /path/to/repo --apply

# Force a specific harness (symmetric — any of codex|claude|cursor|opencode):
legion-delegate run --executor claude --task "Design the data model for X: tradeoffs + a recommendation" --repo /path/to/repo
legion-delegate run --executor codex  --archetype fix-bug --task "Fix the flaky retry in <file>" --repo /path/to/repo --apply

# Independent review of a diff before you act on it:
legion-delegate run --executor codex --archetype final-review --base HEAD --repo /path/to/repo

# Several independent slices in parallel, each routed to its best model:
legion-fanout --slices /tmp/slices.jsonl --repo /path/to/repo --apply

# A whole heavy task with plan + gates + evidence + learning + heal:
legion-run --repo /path/to/repo --task "Add org invitations with tests and review" \
  --plan-file plan.md --validate-command "npm test && npm run build" --json
```

**Do NOT** do coding via `claude --print …`, `codex exec …`, or `opencode run …` directly
— those bypass routing, metering, worktree isolation, and the review gate. If you already
have a script or cron that shells out raw (e.g. the coco implementation cron), switch it to
`legion-delegate run` / `legion-claude run` so the work is metered and inspectable.

## When to delegate to whom

| Need | Executor | Why |
|---|---|---|
| Bulk implementation / mechanical edits / boilerplate | `codex` (default) | throughput at flat subscription cost |
| Deep architecture / system design / hard tradeoffs | `claude` | strongest open-ended reasoner |
| Polished / complex frontend (UX, a11y, responsive) | `claude` | Opus + the `impeccable` skill |
| Final adversarial review before you act | `codex` or `claude` | cross-model verification |
| Cheap/experimental delegation | `opencode` (minimax) | low-cost open harness |

Omit `--executor` to accept the archetype's default route (see `legion-route --list`).
List the harnesses with `legion-route --list-executors`.

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
the orchestration to you.
