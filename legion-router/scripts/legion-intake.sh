#!/usr/bin/env bash

set -euo pipefail

src="${BASH_SOURCE[0]}"
while [ -L "$src" ]; do
  dir="$(cd -P "$(dirname "$src")" >/dev/null 2>&1 && pwd)"
  src="$(readlink "$src")"
  case "$src" in /*) ;; *) src="$dir/$src" ;; esac
done
_self_dir="$(cd -P "$(dirname "$src")" >/dev/null 2>&1 && pwd)"

DELEGATE="${LEGION_DELEGATE_BIN:-$_self_dir/delegate.sh}"
GH="${GH_BIN:-gh}"

die() { printf 'legion-intake: %s\n' "$*" >&2; exit 2; }
note() { printf '%s\n' "$*" >&2; }

usage() {
  cat >&2 <<'EOF'
usage: legion-intake {explore|implement} --issue N --repo OWNER/REPO [--model M]
EOF
  exit 2
}

last_message() {
  local result="$1" msg path
  msg="$(jq -r '.last_message // empty' <<<"$result" 2>/dev/null || true)"
  [[ -n "$msg" ]] && { printf '%s' "$msg"; return; }
  path="$(jq -r '.last_message_path // empty' <<<"$result" 2>/dev/null || true)"
  [[ -n "$path" && -f "$path" ]] && cat "$path"
}

comment_issue() {
  local issue="$1" repo="$2" tag="$3" body="$4"
  printf '%s\n\n%s\n' "$tag" "$body" | "$GH" issue comment "$issue" --repo "$repo" --body-file -
}

base_branch() {
  local repo_dir="$1" branch=""
  branch="$(git -C "$repo_dir" symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null | sed 's@^origin/@@')" || true
  [[ -n "$branch" ]] || branch="$(git -C "$repo_dir" branch --show-current 2>/dev/null || true)"
  [[ -n "$branch" && "$branch" != "HEAD" ]] || branch="main"
  printf '%s' "$branch"
}

mode="${1:-}"; [[ -n "$mode" ]] || usage; shift || true
issue=""; repo=""; model=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --issue) issue="$2"; shift 2 ;;
    --repo) repo="$2"; shift 2 ;;
    --model) model="$2"; shift 2 ;;
    *) usage ;;
  esac
done
[[ "$mode" == "explore" || "$mode" == "implement" ]] || usage
[[ "$issue" =~ ^[0-9]+$ ]] || die "--issue must be a number"
[[ -n "$repo" ]] || die "--repo OWNER/REPO required"
command -v "$GH" >/dev/null 2>&1 || die "gh required. Install gh and run: gh auth login"
command -v jq >/dev/null 2>&1 || die "jq required"
if [[ "$DELEGATE" != */* ]]; then
  DELEGATE="$(command -v "$DELEGATE" 2>/dev/null || true)"
fi
[[ -x "$DELEGATE" ]] || die "legion-delegate not found at $DELEGATE"
"$GH" auth status >/dev/null 2>&1 || die "gh not authenticated. Run: gh auth login"
git rev-parse --is-inside-work-tree >/dev/null 2>&1 || die "run from a checked-out git repo"

issue_json="$("$GH" issue view "$issue" --repo "$repo" --json title,body)"
title="$(jq -r '.title' <<<"$issue_json")"
body="$(jq -r '.body // ""' <<<"$issue_json")"
prompt="$(jq -rn --arg n "$issue" --arg t "$title" --arg b "$body" '
  "GitHub issue #\($n)\n\nTitle: \($t)\n\nBody:\n\($b)"')"
model="${model:-gpt-5.4}"
task="$prompt"
tag="🤖 legion-intake $mode"

# The agent is prompted with USER-CONTROLLED issue text, so a prompt injection
# could try to read tokens from the environment and echo them into its output
# (which we post back to the issue/PR). Run the delegated agent with the GitHub +
# provider secrets SCRUBBED from its environment — the workflow writes codex auth
# to ~/.codex/auth.json, so codex still authenticates without these env vars,
# while `gh` posting below keeps GH_TOKEN in this parent shell.
agent() { env -u GH_TOKEN -u GITHUB_TOKEN -u CODEX_AUTH -u OPENAI_API_KEY "$DELEGATE" "$@"; }

if [[ "$mode" == "explore" ]]; then
  task="$task"$'\n\n'"Return: a short assessment — root cause if visible, the files involved, and whether this is safe to auto-implement (yes/no) with one-line reasoning."
  set +e
  result="$(agent run --sandbox read-only --model "$model" --task "$task" --repo "$PWD")"
  rc=$?
  set -e
  summary="$(last_message "$result")"
  [[ "$rc" -eq 0 ]] || summary="${summary:-delegate failed}"
  comment_issue "$issue" "$repo" "$tag" "$summary"
  exit 0
fi

set +e
result="$(agent run --sandbox workspace-write --model "$model" --task "$task" --repo "$PWD")"
rc=$?
set -e
status="$(jq -r '.status // "failed"' <<<"$result" 2>/dev/null || echo failed)"
diff="$(jq -r '.diff_path // empty' <<<"$result" 2>/dev/null || true)"
summary="$(last_message "$result")"
if [[ "$rc" -ne 0 || "$status" != "ok" || -z "$diff" || ! -s "$diff" ]]; then
  why="delegate status=$status"
  [[ -n "$diff" && ! -s "$diff" ]] && why="no changes produced"
  comment_issue "$issue" "$repo" "$tag" "${why}${summary:+$'\n\n'"$summary"}"
  exit 0
fi

# Unique per run: a fixed agent/issue-N branch would diverge from its remote on a
# rerun and the push would be rejected (non-fast-forward). Suffix with the
# delegate run id (unique + traceable) so each run opens a fresh branch/PR.
run_id="$(jq -r '.run_id // empty' <<<"$result" 2>/dev/null || true)"
branch="agent/issue-$issue${run_id:+-$run_id}"
base="$(base_branch "$PWD")"
git checkout -B "$branch" >/dev/null 2>&1
git apply --check "$diff" || die "delegate diff does not apply cleanly"
git apply "$diff"
git add -A
git -c user.name=legion-intake -c user.email=legion-intake@users.noreply.github.com \
  commit -m "$title" -m "Closes #$issue" >/dev/null
git push -u origin "$branch" >/dev/null 2>&1
pr_body="$(printf 'Closes #%s\n\n%s\n' "$issue" "${summary:-Agent implementation from legion-intake.}")"
"$GH" pr create --repo "$repo" --base "$base" --head "$branch" --title "$title" --body "$pr_body" >/dev/null
note "opened PR for issue #$issue on $branch"
