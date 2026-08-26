# Hermes as a symmetric Legion primary

Hermes is a registered Legion executor as well as a primary. It can work inline
when it has the needed context, and can make a single explicit handoff to any
**different** registered executor for independent implementation or review.
Every delegated run remains metered (`legion.span.v1`) instead of
shelling out raw and off-book.

Two pieces make this work:

1. **`legion-hermes-mode`** (this repo) — the primary-mode skill that tells a
   Hermes session when to work inline and when to use the symmetric Legion
   handoff from its `terminal` tool.
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
  --model "$(legion-route --model-ref claude_default)" \
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

- Both the primary Claude path and the Codex fallback run in isolated worktrees
  and return unapplied diffs unless `--apply` is explicit. The fallback uses a
  different configured model and effort from the primary Claude route.
- So for an unattended implementation lane, prefer **`--no-fallback`**: fail loudly
  and let the next run retry, rather than silently switch models and land nothing
  while reporting success. Drop `--no-fallback` only if you genuinely want the
  cross-model *unapplied* result (e.g. a review/plan lane).

### A note on worktree isolation

`legion-claude` creates a git worktree under `.legion/worktrees/`, captures the
result under `.legion/runs/<run-id>/diff.patch`, and removes the worktree by
default. It fails closed if isolation cannot be established. Use `--keep` to
retain the worktree and `--apply` only after reviewing the diff.

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

## Making the skill discoverable to Hermes

The Legion installer exposes the mode skill through the shared catalog, then
`legion-setup hermes` creates one managed link in the directory Hermes actually
scans. It does not rewrite Hermes configuration or replace an existing real
skill directory:

```bash
legion-setup hermes
legion-setup hermes verify
```

The managed path is
`~/.hermes/skills/legion-hermes-mode -> ~/.agents/skills/legion-hermes-mode`.
Hermes then discovers the guidance when it needs to build, fix, review, or
delegate code. Setup records the exact managed source separately; uninstall
removes the link only while it still points there, preserving any link an
operator has replaced.
