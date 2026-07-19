# Hermes as a metered Legion primary

Hermes is a long-running persona / messaging assistant / orchestrator — **not** a
headless coding CLI like Codex or opencode. So it integrates with Legion as a
**primary that delegates**, and the goal is to make those delegations **metered**
(emit `legion.span.v1` telemetry) instead of shelling out raw and off-book.

Two pieces make this work:

1. **`legion-hermes-mode`** (this repo) — the brain skill that tells a hermes
   session to delegate coding through the Legion CLIs from its `terminal` tool, and
   when to reach for which harness.
2. **The operational rewire (below)** — point hermes's existing coding cron/scripts
   at `legion-claude run` / `legion-delegate run` instead of a raw `claude --print`
   / `codex exec`.

> Scope note: legion-core is model-agnostic and holds **no domain content**. The
> generic mechanism lives here; your domain-specific task prompt, target repo, and
> cron wiring stay in your own agent/operator environment.

## The gap this closes

A typical hermes coding lane is a script (often on a hermes cron) that shells out to
a **raw `claude --print`**:

```bash
claude --print --model opus --effort high --dangerously-skip-permissions \
  --append-system-prompt "…" "$(< "$PROMPT_FILE")" 2>&1 | tee -a "$LOG"
```

That produces no Legion span, so the work never shows in `legion-share` /
`legion-report` / the Console. It bypasses routing, metering, and (for the
diff-producing executors) worktree isolation.

## The rewire

`legion-claude run` now accepts the flags an autonomous run needs (`--effort`,
`--append-system-prompt`, `--dangerously-skip-permissions`), so it is a **drop-in,
span-emitting** replacement. Swap the raw block for:

```bash
LEGION_PRIMARY=hermes LEGION_TARGET_TYPE=cron LEGION_TARGET_NAME="<lane-name>" \
legion-claude run \
  --repo "$REPO" \
  --model opus \
  --effort high \
  --dangerously-skip-permissions \
  --no-fallback \
  --append-system-prompt "…" \
  --task "$(< "$PROMPT_FILE")" > "$LOG.json" 2>>"$LOG"
rc=$?
jq -r '.result // .last_message // empty' "$LOG.json" | tee -a "$LOG"   # human transcript
[[ "$rc" -eq 0 && "$(jq -r .status "$LOG.json")" == "ok" ]] || exit "$rc"   # surface real failures
```

A complete, templated example is
[`docs/hermes/metered-delegation.example.sh`](hermes/metered-delegation.example.sh).

What changes:

- **Metered:** a `legion.span.v1` span (executor `claude`, cost, latency, tokens)
  lands in the harness-neutral state root and shows in `legion-report` /
  `legion-share`.
- **Attributed:** `LEGION_PRIMARY=hermes` marks hermes as the orchestrator; the
  `LEGION_TARGET_*` vars tag the run.
- **Failures surface:** capture the exit code and the run's `.status`, and exit
  non-zero on `blocked`/`failed` — don't `|| true` a real failure into a "completed"
  log that a cron reads as success.

### `--no-fallback` for implementation lanes (important)

`legion-claude` can fall back to the configured Codex workhorse on a Claude
usage-limit. Be deliberate about that for a *coding* lane:

- The primary Claude path runs `claude -p` **in-place** in `$REPO` (it edits the
  working tree). The fallback runs Codex via `legion-delegate` in an **isolated
  worktree with no `--apply`**, so it returns an *unapplied* diff and **lands no code
  in your repo**. It also runs on a **different model** at the configured effort, not
  your chosen `opus --effort high`.
- So for an unattended implementation lane, prefer **`--no-fallback`**: fail loudly
  and let the next run retry, rather than silently switch models and land nothing
  while reporting success. Drop `--no-fallback` only if you genuinely want the
  cross-model *unapplied* result (e.g. a review/plan lane).

### A note on worktree isolation

`legion-claude` (the "prompt" executor) runs `claude -p` **in-place** in the repo —
it does *not* use a worktree. The worktree isolation the `-mode` skills describe
applies to the **diff-producing** executors (codex/cursor/opencode via
`legion-delegate run --executor …`). Choose `legion-delegate run --executor …` when
you want the change captured as a reviewable diff in an isolated worktree instead of
applied in-place.

## Ordering (important)

The rewire depends on **this repo's `legion-claude`** (the autonomous-run flags), so
apply it only **after** the Legion install is repointed at this branch:

1. Land / install this branch (repoint your Legion source clone, e.g.
   `~/.agents/sources/legion-core`, and re-run `legion-setup`).
2. Back up the live script before swapping it.
3. Apply the metered version (adapt the example to your lane's repo + prompt).
4. Verify: run the lane once and confirm a run dir under your lane log dir **plus** a
   span — `legion-report --window 1d --json | jq '.by_executor'` should now show the
   hermes-driven Claude work (previously invisible).

Do **not** apply before step 1 — an older installed `legion-claude` rejects
`--append-system-prompt`, which would break the lane.

## Making the skill discoverable to hermes

Hermes reads its skills from `~/.hermes/skills/`. Symlink the brain skill so a hermes
session picks it up:

```bash
ln -s <install>/legion-hermes-mode ~/.hermes/skills/<category>/legion-hermes-mode
```

(or copy it there). It then triggers when hermes needs to build, fix, or review code.
