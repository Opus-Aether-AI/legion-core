#!/usr/bin/env bash
# legion-heal — detect → delegate-fix → gate → open PR. Auto-healing built ONLY
# from Legion's own primitives; it invents no fixer of its own:
#
#   detect  : legion-doctor --json   (the static guards)
#   fix     : legion-delegate run --apply   (codex in an isolated worktree → diff)
#   gate    : legion-doctor (re-check) + bats tests/   (the scorecard checks)
#   verify  : legion-delegate review   (independent cross-model verdict)
#   ship    : gh pr create            (NEVER --merge, NEVER auto-merge)
#
# Safe by construction: opt-in, capped (--max), idempotent (deterministic
# legion-heal/<check>-<hash> branch; skips a finding that already has an open PR),
# and --dry-run shows the plan with zero side effects.
#
#   legion-heal plan [--repo DIR] [--severity fail|warn]
#   legion-heal run  [--repo DIR] [--max N] [--budget-tokens T] [--base REF]
#                    [--dry-run] [--no-pr] [--no-verify] [--archetype A]
#
# Tool bins are env-injectable for tests: LEGION_DOCTOR_BIN, LEGION_DELEGATE_BIN,
# GH_BIN, BATS_BIN.
set -uo pipefail

_self="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_root="$(cd "$_self/../.." && pwd)"

DOCTOR="${LEGION_DOCTOR_BIN:-$_root/legion-observability/bin/legion-doctor}"
DELEGATE="${LEGION_DELEGATE_BIN:-legion-delegate}"
GH="${GH_BIN:-gh}"
BATS="${BATS_BIN:-bats}"

# Checks legion-heal will attempt to auto-fix. codex/router are environmental
# (auth / running service), not code defects — never auto-fixed.
HEALABLE="descriptions mcp bridges frontmatter marketplace-schema plugins costs telemetry-schema"

note() { printf '%s\n' "$*" >&2; }
die()  { printf 'legion-heal: %s\n' "$*" >&2; exit 2; }

_sha8() {
  local h
  h="$(printf '%s' "$1" | { shasum 2>/dev/null || sha1sum 2>/dev/null; } | cut -c1-8)"
  # Portable last resort (cksum is POSIX) so a missing shasum/sha1sum never
  # collapses every branch name onto the same empty hash.
  [[ -n "$h" ]] || h="$(printf '%s' "$1" | cksum | tr -cd '0-9' | cut -c1-8)"
  printf '%s' "$h"
}

_is_healable() {  # check-name
  local c; for c in $HEALABLE; do [[ "$c" == "$1" ]] && return 0; done; return 1
}

# Guard against a "fix" that satisfies a check by DELETING its backing artifact.
# legion-doctor's costs / telemetry-schema checks WARN (exit 0) when the file is
# absent — that absence is correct for a consumer that doesn't vendor the engine,
# but in a heal worktree it means `--only <check>` alone would green-light a
# delegate that simply `rm`-ed an invalid file. Require the artifact to survive.
_artifact_survived() {  # check  worktree
  local pat=""
  case "$1" in
    costs)            pat='*/legion-router/config/costs.json' ;;
    telemetry-schema) pat='*/legion-observability/schema/legion.span.v1.schema.json' ;;
    *) return 0 ;;  # check has no delete-sensitive artifact
  esac
  [[ -n "$(find "$2" -path "$pat" -not -path '*/.git/*' 2>/dev/null | head -1)" ]]
}

_slug() {  # repo-dir → owner/name from the origin remote URL
  local url; url="$(git -C "$1" remote get-url origin 2>/dev/null)" || return 1
  url="${url%.git}"; url="${url#git@*:}"; url="${url#https://*/}"
  printf '%s\n' "$url"
}

# Collect fixable findings as compact JSON lines on stdout.
_findings() {  # repo  severity
  local repo="$1" sev="$2"
  LEGION_ROOT="$repo" "$DOCTOR" --repo "$repo" --json 2>/dev/null \
    | jq -c --arg sev "$sev" '.[] | select(.severity == $sev)'
}

_fix_prompt() {  # check  message  entity  repo
  cat <<EOF
You are fixing a single Legion marketplace defect that legion-doctor flagged.

Check:   $1
Entity:  $3
Problem: $2

Make the SMALLEST change that makes \`legion-doctor --only $1\` pass, without
breaking \`bats tests/\`. Follow repo conventions in CLAUDE.md / AGENTS.md.

Hard rules:
- Do NOT edit files under vendored/ directly — they are re-imported by
  scripts/vendor.sh. If the fix belongs to a vendored skill, fix it in
  scripts/vendor.sh (or scripts/lib/) so the normalization survives re-vendoring,
  then apply the same transform to the affected vendored file(s).
- For a missing/404 MCP package, replace it with the correct, currently-published
  package; do not delete the server unless no published package exists.
- Keep the diff focused on this one finding. No drive-by refactors.
EOF
}

# Heal a single finding. Echoes a status word. All side effects gated by DRY_RUN.
heal_one() {
  local repo="$1" finding="$2" base="$3"
  local check msg entity
  check="$(jq -r '.check' <<<"$finding")"
  msg="$(jq -r '.message' <<<"$finding")"
  entity="$(jq -r '.entity // ""' <<<"$finding")"

  _is_healable "$check" || { note "  skip (not healable): $check — $msg"; echo skipped; return; }

  local branch slug; branch="legion-heal/${check}-$(_sha8 "$check:$msg")"

  # Dry-run is fully inert: no external calls, no git state, just the plan.
  if [[ "$DRY_RUN" == "1" ]]; then
    note "  → $check: $msg"; note "    branch: $branch"
    note "    (dry-run: would delegate + gate + PR)"; echo planned; return
  fi

  slug="$(_slug "$repo" 2>/dev/null || true)"
  # Idempotency: an open PR or an existing remote branch means it's already queued.
  if [[ -n "$slug" ]] && "$GH" pr list --repo "$slug" --head "$branch" --state open \
        --json number 2>/dev/null | jq -e 'length > 0' >/dev/null 2>&1; then
    note "  skip (PR already open): $branch"; echo skipped; return
  fi
  if git -C "$repo" ls-remote --exit-code --heads origin "$branch" >/dev/null 2>&1; then
    note "  skip (branch exists on remote): $branch"; echo skipped; return
  fi

  note "  → $check: $msg"
  note "    branch: $branch"

  # Isolated heal worktree on a fresh branch off base.
  local wt; wt="$(mktemp -d)/heal"
  git -C "$repo" worktree add -q "$wt" -b "$branch" "$base" 2>/dev/null || {
    note "    could not create worktree for $branch"; echo failed; return; }

  local cleanup_rc=0
  _cleanup() { git -C "$repo" worktree remove --force "$wt" >/dev/null 2>&1 || rm -rf "$wt"; }

  # FIX — delegate to codex; --apply lands the diff in the heal worktree.
  local dargs=(run --repo "$wt" --base "$base" --apply --sandbox workspace-write)
  [[ -n "$ARCHETYPE" ]] && dargs+=(--archetype "$ARCHETYPE")
  [[ -n "$BUDGET" ]] && dargs+=(--budget-tokens "$BUDGET")
  if ! "$DELEGATE" "${dargs[@]}" --task "$(_fix_prompt "$check" "$msg" "$entity" "$repo")" >"$wt/.heal-delegate.json" 2>"$wt/.heal-delegate.err"; then
    note "    delegate failed (see $wt/.heal-delegate.err)"; _cleanup; echo failed; return
  fi
  if git -C "$wt" diff --quiet 2>/dev/null && git -C "$wt" diff --cached --quiet 2>/dev/null; then
    note "    delegate produced no change"; _cleanup; echo failed; return
  fi

  # GATE — the finding's own check must now pass, and nothing else may break.
  if ! LEGION_ROOT="$wt" "$DOCTOR" --repo "$wt" --only "$check" >/dev/null 2>&1; then
    note "    gate failed: $check still red after fix"; _cleanup; echo rejected; return
  fi
  # …and it must not have passed by deleting the artifact it was meant to repair.
  if ! _artifact_survived "$check" "$wt"; then
    note "    gate failed: $check 'fixed' by deleting its artifact"; _cleanup; echo rejected; return
  fi
  if [[ -d "$wt/tests" ]] && command -v "$BATS" >/dev/null 2>&1; then
    if ! "$BATS" "$wt/tests/" >/dev/null 2>&1; then
      note "    gate failed: bats tests/ red after fix"; _cleanup; echo rejected; return
    fi
  fi

  # VERIFY — independent cross-model review (advisory: blocks only on explicit reject).
  local verdict="(skipped)"
  if [[ "$NO_VERIFY" != "1" ]]; then
    local vj; vj="$("$DELEGATE" review --repo "$wt" --base "$base" 2>/dev/null || true)"
    if [[ -n "$vj" ]]; then
      verdict="$(jq -r '.summary // .verdict // "reviewed"' <<<"$vj" 2>/dev/null || echo reviewed)"
      if jq -e '(.approve == false) or (.verdict == "reject")' <<<"$vj" >/dev/null 2>&1; then
        note "    cross-model review rejected the fix"; _cleanup; echo rejected; return
      fi
    fi
  fi

  # SHIP — commit, push, open PR. Never merge.
  git -C "$wt" add -A
  # Never let legion's own runtime state leak into a heal PR. delegate.sh writes
  # .legion/.gitignore (`*`), but a .gitignore can't ignore itself, so `add -A`
  # would otherwise stage it. Drop the whole .legion/ dir from the commit.
  git -C "$wt" reset -q -- .legion 2>/dev/null || true
  git -C "$wt" -c commit.gpgsign=false commit -q -m "fix(heal): $check — ${msg:0:60}" \
    -m "Auto-healed by legion-heal from a legion-doctor finding." \
    -m "Co-Authored-By: legion-heal <noreply@legion-core>" 2>/dev/null
  if [[ "$NO_PR" == "1" ]]; then
    note "    --no-pr: fix committed on $branch (not pushed)"; echo "healed:$branch"; cleanup_rc=1
  else
    if ! git -C "$wt" push -q -u origin "$branch" 2>/dev/null; then
      note "    push failed for $branch"; _cleanup; echo failed; return
    fi
    local body
    # shellcheck disable=SC2016  # backticks are literal markdown in the PR body
    body="$(printf 'Auto-healed by **legion-heal** from a \`legion-doctor\` finding.\n\n**Check:** `%s`\n**Finding:** %s\n\nGate: `legion-doctor --only %s` + `bats tests/` pass.\nCross-model review: %s\n\nNot auto-merged — review required.\n\n🤖 legion-heal' "$check" "$msg" "$check" "$verdict")"
    if [[ -n "$slug" ]] && "$GH" pr create --repo "$slug" --base "$base" --head "$branch" \
        --title "fix(heal): $check — ${msg:0:60}" --body "$body" >/dev/null 2>&1; then
      note "    ✓ PR opened for $branch"; echo "healed:$branch"
    else
      note "    PR create failed (branch pushed: $branch)"; echo "pushed:$branch"
    fi
  fi
  [[ "$cleanup_rc" == "0" ]] && _cleanup
}

cmd_plan() {
  local repo="$1" sev="$2" n=0 fixable=0
  note "legion-heal plan — $repo (severity: $sev)"
  while IFS= read -r f; do
    [[ -z "$f" ]] && continue
    n=$((n + 1))
    local check msg; check="$(jq -r '.check' <<<"$f")"; msg="$(jq -r '.message' <<<"$f")"
    if _is_healable "$check"; then
      fixable=$((fixable + 1)); note "  [fixable] $check: $msg"
    else
      note "  [manual ] $check: $msg"
    fi
  done < <(_findings "$repo" "$sev")
  note "── $n finding(s), $fixable auto-fixable ──"
  [[ "$n" -eq 0 ]]
}

cmd_run() {
  local repo="$1" base="$2" max="$3" sev="$4"
  command -v "$GH" >/dev/null 2>&1 || [[ "$DRY_RUN" == "1" || "$NO_PR" == "1" ]] || die "gh not found (needed to open PRs)"
  local count=0 healed=0 rejected=0 failed=0
  while IFS= read -r f; do
    [[ -z "$f" ]] && continue
    local check; check="$(jq -r '.check' <<<"$f")"
    _is_healable "$check" || continue
    if [[ "$count" -ge "$max" ]]; then note "  (--max $max reached; stopping)"; break; fi
    count=$((count + 1))
    local r; r="$(heal_one "$repo" "$f" "$base")"
    case "$r" in
      healed:*|pushed:*) healed=$((healed + 1)) ;;
      rejected) rejected=$((rejected + 1)) ;;
      failed)   failed=$((failed + 1)) ;;
    esac
  done < <(_findings "$repo" "$sev")
  note "── legion-heal: $healed healed, $rejected rejected, $failed failed (of $count attempted) ──"
  [[ "$failed" -eq 0 ]]
}

# ── arg parse ───────────────────────────────────────────────────────────
SUB="${1:-}"; shift || true
# Default archetype: legion-delegate requires --archetype or --model. "fix-bug"
# resolves model/sandbox/effort from routing.toml for a scoped defect fix.
REPO=""; BASE="main"; MAX=3; SEV="fail"; BUDGET=""; ARCHETYPE="fix-bug"
DRY_RUN=0; NO_PR=0; NO_VERIFY=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --repo) REPO="$2"; shift 2 ;;
    --base) BASE="$2"; shift 2 ;;
    --max) MAX="$2"; shift 2 ;;
    --severity) SEV="$2"; shift 2 ;;
    --budget-tokens) BUDGET="$2"; shift 2 ;;
    --archetype) ARCHETYPE="$2"; shift 2 ;;
    --dry-run) DRY_RUN=1; shift ;;
    --no-pr) NO_PR=1; shift ;;
    --no-verify) NO_VERIFY=1; shift ;;
    -h|--help) sed -n '2,20p' "$_self/$(basename "${BASH_SOURCE[0]}")" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) die "unknown arg '$1'" ;;
  esac
done
[[ -n "$REPO" ]] || REPO="$(git -C "$_self" rev-parse --show-toplevel 2>/dev/null || echo "$_root")"
command -v jq >/dev/null 2>&1 || die "jq required"
[[ -x "$DOCTOR" ]] || die "legion-doctor not found at $DOCTOR"

case "$SUB" in
  plan) cmd_plan "$REPO" "$SEV" ;;
  run)  cmd_run "$REPO" "$BASE" "$MAX" "$SEV" ;;
  ""|-h|--help) sed -n '2,20p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
  *) die "unknown subcommand '$SUB' (use: plan | run)" ;;
esac
