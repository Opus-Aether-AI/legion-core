#!/usr/bin/env bash
# Example: a hermes coding lane, METERED through Legion.
#
# A generic, templated illustration of the rewire in docs/hermes-integration.md —
# turn a raw `claude --print …` cron/script into a `legion-claude run …` that emits
# a legion.span.v1 span (cost/latency/tokens, attributed to hermes) so the work
# shows in legion-report / legion-share instead of vanishing off-book.
#
# This is an EXAMPLE, not a drop-in: keep your domain-specific task prompt, repo,
# and paths in your own agent/operator environment (legion-core is model-agnostic
# and holds no domain content). Supply REPO + PROMPT_FILE; everything else has a
# sane default.
#
# REQUIRES the legion-claude autonomous-run flags (--effort / --append-system-prompt
# / --dangerously-skip-permissions) from this build — apply only after the Legion
# install is repointed at it (an older legion-claude rejects --append-system-prompt).
set -euo pipefail

REPO="${REPO:?set REPO to the target git repository}"
PROMPT_FILE="${PROMPT_FILE:?set PROMPT_FILE to a file containing the task prompt}"
MODEL_REF="${LEGION_LANE_MODEL_REF:-claude_default}"
MODEL="${LEGION_LANE_MODEL:-$(legion-route --model-ref "$MODEL_REF")}"
EFFORT="${LEGION_LANE_EFFORT:-high}"
SYSTEM_PROMPT="${LEGION_LANE_SYSTEM_PROMPT:-}"
[[ -n "$SYSTEM_PROMPT" ]] || SYSTEM_PROMPT="Use the installed Legion marketplace skills when relevant. Respect the task safety constraints exactly."
LOG_DIR="${LEGION_LANE_LOG_DIR:-${LEGION_STATE_ROOT:-$HOME/.legion}/hermes-lanes}"
mkdir -p "$LOG_DIR"
STAMP="$(date '+%Y%m%dT%H%M%S%z')"
LOG="$LOG_DIR/lane-$STAMP.log"

printf 'hermes metered lane started: %s\nrepo: %s\nprompt: %s\n\n' \
  "$(date -Iseconds)" "$REPO" "$PROMPT_FILE" | tee "$LOG"

# --no-fallback: this is an IMPLEMENTATION lane, so fail loudly rather than let a
# Claude usage-limit silently switch models. (Legion's default Codex fallback runs
# in an isolated worktree WITHOUT --apply, so it would not land code here anyway;
# drop --no-fallback only if you genuinely want the unapplied cross-model result.)
# Metered: legion-claude runs `claude -p` headless with the same model/effort/
# system-prompt/skip-permissions and emits a legion.span.v1 span attributed to hermes.
set +e
LEGION_PRIMARY=hermes LEGION_TARGET_TYPE=cron LEGION_TARGET_NAME="${LEGION_LANE_NAME:-hermes-lane}" \
legion-claude run \
  --repo "$REPO" \
  --model "$MODEL" \
  --effort "$EFFORT" \
  --dangerously-skip-permissions \
  --no-fallback \
  --append-system-prompt "$SYSTEM_PROMPT" \
  --task "$(< "$PROMPT_FILE")" > "$LOG.json" 2>>"$LOG"
rc=$?
set -e

# Human-readable transcript alongside the metered JSON envelope.
jq -r '.result // .last_message // empty' "$LOG.json" 2>/dev/null | tee -a "$LOG" || true
status="$(jq -r '.status // "unknown"' "$LOG.json" 2>/dev/null || echo unknown)"

printf '\nhermes metered lane finished: %s\nstatus: %s (exit %s)\nlog: %s\nspan/JSON: %s\n' \
  "$(date -Iseconds)" "$status" "$rc" "$LOG" "$LOG.json" | tee -a "$LOG"

# Surface real failure to the caller/cron instead of always reporting success.
[[ "$rc" -eq 0 && "$status" == "ok" ]] || exit "${rc:-1}"
