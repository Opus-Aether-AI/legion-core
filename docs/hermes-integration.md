# Hermes as a metered Legion primary

Hermes is a long-running persona / messaging assistant / orchestrator — **not** a
headless coding CLI like Codex or opencode. So it integrates with Legion as a
**primary that delegates**, and the goal is to make those delegations **metered**
(emit `legion.span.v1` telemetry) instead of shelling out raw and off-book.

Two pieces make this work:

1. **`legion-hermes-mode`** (this repo) — the routing-brain skill that tells a
   hermes session to delegate coding through the Legion CLIs from its `terminal`
   tool, and when to reach for which harness.
2. **The operational rewire (below)** — point hermes's existing coding cron/scripts
   at `legion-claude run` / `legion-delegate run` instead of a raw `claude --print`
   / `codex exec`.

## The gap this closes

Today hermes's COCO implementation lane
(`~/.hermes/scripts/coco_legion_claude_implementation.sh`, triggered by hermes cron
`a4fa757d8ec1`) runs:

```bash
LEGION_MARKETPLACE_ROOT=/Users/ithihas/.agents/sources/legion \
claude --print --model opus --effort high --dangerously-skip-permissions \
  --append-system-prompt "…" "$(< "$PROMPT_FILE")" 2>&1 | tee -a "$LOG"
```

That's a **raw `claude --print`** — it produces no Legion span, so the work never
shows in `legion-share` / `legion-report` / the Console. It bypasses routing,
metering, and worktree isolation.

## The rewire

`legion-claude run` now accepts the flags an autonomous run needs
(`--effort`, `--append-system-prompt`, `--dangerously-skip-permissions`), so it is a
**drop-in, span-emitting** replacement. Swap the raw block for:

```bash
LEGION_PRIMARY=hermes LEGION_TARGET_TYPE=cron LEGION_TARGET_NAME=coco-execution-gate \
legion-claude run \
  --repo "$REPO" \
  --model opus \
  --effort high \
  --dangerously-skip-permissions \
  --append-system-prompt "Use the installed Legion marketplace skills when relevant. Respect the COCO safety constraints in the task prompt exactly." \
  --task "$(< "$PROMPT_FILE")" > "$LOG.json" 2>>"$LOG"
# human-readable transcript alongside the metered JSON envelope:
jq -r '.result // .last_message // empty' "$LOG.json" 2>/dev/null | tee -a "$LOG"
```

What changes:

- **Metered:** a `legion.span.v1` span (executor `claude`, cost, latency, tokens)
  lands in the harness-neutral state root and shows in `legion-report` / `legion-share`.
- **Attributed:** `LEGION_PRIMARY=hermes` marks hermes as the orchestrator; the
  `LEGION_TARGET_*` vars tag the run.
- **Resilient:** on a Claude usage limit, `legion-claude` auto-falls back to the
  configured Codex workhorse (`--no-fallback` to opt out) — the raw call just failed.
- **Same safety envelope:** identical model / effort / system-prompt /
  skip-permissions, so the COCO safety constraints are unchanged.

The prepared, ready-to-apply script is at
`docs/hermes/coco_legion_claude_implementation.metered.sh` in this repo.

## Ordering (important)

The rewire depends on **this repo's `legion-claude`** (the autonomous-run flags),
so apply it only **after** the Legion install is repointed at this branch:

1. Land / install this branch (repoint `~/.agents/sources/legion-core`).
2. Back up the live script:
   `cp ~/.hermes/scripts/coco_legion_claude_implementation.sh{,.bak}`
3. Apply the metered version.
4. Verify: run the lane once and confirm a run dir under
   `~/.hermes/state/legion-runs` **plus** a span —
   `legion-report --window 1d --json | jq '.by_executor'` should now show the
   hermes-driven Claude work (previously invisible).

Do **not** apply before step 1 — an older installed `legion-claude` rejects
`--append-system-prompt`, which would break the cron.

## Making the skill discoverable to hermes

Hermes reads its skills from `~/.hermes/skills/`. Symlink the brain skill so a
hermes session picks it up:

```bash
ln -s <install>/legion-hermes-mode ~/.hermes/skills/autonomous-ai-agents/legion-hermes-mode
```

(or copy it there). It then triggers when hermes needs to build/fix/review code.
