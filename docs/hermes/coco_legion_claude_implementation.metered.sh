#!/usr/bin/env bash
# One-shot, user-authorized Claude/Legion implementation lane for COCO — METERED.
#
# Drop-in replacement for ~/.hermes/scripts/coco_legion_claude_implementation.sh.
# Identical safety envelope + model/effort/system-prompt, but routes through
# `legion-claude run` so the work emits a legion.span.v1 span (shows in
# legion-report / legion-share / the Console) instead of a raw, off-book
# `claude --print`.
#
# REQUIRES the legion-core build that adds legion-claude's autonomous-run flags
# (--effort / --append-system-prompt / --dangerously-skip-permissions). Apply
# only after the Legion install is repointed at that build. See
# docs/hermes-integration.md.
set -euo pipefail

REPO="/Users/ithihas/Code/coco-mt5-execution-gate"
LOG_DIR="/Users/ithihas/.hermes/state/legion-runs"
mkdir -p "$LOG_DIR"
STAMP="$(date '+%Y%m%dT%H%M%S%z')"
LOG="$LOG_DIR/coco-claude-$STAMP.log"
PROMPT_FILE="$LOG_DIR/coco-claude-$STAMP.prompt.txt"

cat > "$PROMPT_FILE" <<'PROMPT'
You are the implementation lane for the COCO MT5 Execution Gate repository.

Use the installed Legion marketplace/skills. Work only in this repository.

Mission: implement only safe, deterministic no-agent components required to replace routine COCO monitoring/execution/journaling/lifecycle/notification orchestration. Preserve one explicit AI boundary: AI may classify an already-qualified candidate setup, but may not run routinely for monitoring, state movement, broker execution, journaling, close/lifecycle, Aether synchronization, or notifications.

Hard safety constraints:
- Do NOT touch ~/.hermes cron configuration or resume/pause any jobs.
- Do NOT place, modify, or close a broker trade; do not call a live API.
- Do NOT alter credentials, secrets, auth files, account settings, or remote services.
- Do NOT reset, checkout, stash, discard, or overwrite pre-existing uncommitted work. First inspect git diff/status and treat it as another worker's work.
- Do NOT commit or push.
- Do NOT redesign V1/V2 contracts. Keep their state schemas and existing demo behavior compatible.
- If a necessary external operation cannot be implemented without runtime credentials/side effects, create a testable deterministic interface/adapter and document the boundary instead of faking it.

Required process:
1. Read docs/operator-runbook.md, legion-plan.json, src/, tests/, and existing git diff.
2. Identify the smallest missing deterministic contract/adapter that can safely move an already approved decision through a durable idempotent outbox/receipt boundary without invoking an LLM.
3. Implement the minimal code plus focused tests. Do not touch fixture wording except where a test contract explicitly needs it.
4. Run the focused tests and then the full existing test suite. Run compile checks.
5. End with a concise report: files changed, behavior added, commands/results, remaining external integration blocker(s), and confirmation that no cron or broker side effect occurred.

If the existing uncommitted diff already implements the required safe deterministic contract, do not duplicate it: review it, add only missing tests or corrections that you can prove, and report that finding.
PROMPT

cd "$REPO"
printf 'COCO Legion Claude run started: %s\n' "$(date -Iseconds)" | tee "$LOG"
printf 'Repository: %s\nPrompt: %s\n\n' "$REPO" "$PROMPT_FILE" | tee -a "$LOG"

# Metered: legion-claude runs `claude -p` headless with the same model/effort/
# system-prompt/skip-permissions, emits a legion.span.v1 span (attributed to
# hermes), and auto-falls back to Codex on a Claude usage limit. No model/API key
# is exposed to this script. The JSON envelope goes to $LOG.json; the human
# transcript is appended to $LOG.
LEGION_PRIMARY=hermes LEGION_TARGET_TYPE=cron LEGION_TARGET_NAME=coco-execution-gate \
LEGION_MARKETPLACE_ROOT="/Users/ithihas/.agents/sources/legion" \
legion-claude run \
  --repo "$REPO" \
  --model opus \
  --effort high \
  --dangerously-skip-permissions \
  --append-system-prompt "Use the installed Legion marketplace skills when relevant. Respect the COCO safety constraints in the task prompt exactly." \
  --task "$(< "$PROMPT_FILE")" > "$LOG.json" 2>>"$LOG" || true
jq -r '.result // .last_message // empty' "$LOG.json" 2>/dev/null | tee -a "$LOG"

printf '\nCOCO Legion Claude run completed: %s\nLog: %s\nSpan/JSON: %s\n' \
  "$(date -Iseconds)" "$LOG" "$LOG.json" | tee -a "$LOG"
