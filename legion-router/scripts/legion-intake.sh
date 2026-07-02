#!/usr/bin/env bash

set -euo pipefail

src="${BASH_SOURCE[0]}"
while [ -L "$src" ]; do
  dir="$(cd -P "$(dirname "$src")" >/dev/null 2>&1 && pwd)"
  src="$(readlink "$src")"
  case "$src" in /*) ;; *) src="$dir/$src" ;; esac
done
_self_dir="$(cd -P "$(dirname "$src")" >/dev/null 2>&1 && pwd)"

GH="${GH_BIN:-gh}"

die() { printf 'legion-intake: %s\n' "$*" >&2; exit 2; }
note() { printf '%s\n' "$*" >&2; }

usage() {
  cat >&2 <<'EOF'
usage: legion-intake {explore|implement} --issue N --repo OWNER/REPO
                    [--archetype A] [--model M]
                    [--worker delegate|cursor|custom] [--worker-bin CMD]
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

resolve_worker() {
  local requested="$1" explicit_bin="$2"
  worker="$requested"
  [[ -n "$worker" ]] || worker="${LEGION_INTAKE_WORKER:-delegate}"
  worker_bin="$explicit_bin"

  case "$worker" in
    delegate)
      worker_bin="${worker_bin:-${LEGION_INTAKE_WORKER_BIN:-${LEGION_DELEGATE_BIN:-$_self_dir/delegate.sh}}}"
      default_model=""
      untrusted_flag="--untrusted"
      ;;
    cursor)
      worker_bin="${worker_bin:-${LEGION_INTAKE_WORKER_BIN:-${LEGION_CURSOR_BIN:-$_self_dir/legion-cursor.sh}}}"
      default_model="${LEGION_CURSOR_MODEL:-${CURSOR_MODEL:-composer-2.5}}"
      untrusted_flag=""
      ;;
    custom)
      worker_bin="${worker_bin:-${LEGION_INTAKE_WORKER_BIN:-}}"
      default_model=""
      untrusted_flag=""
      [[ -n "$worker_bin" ]] || die "--worker custom requires --worker-bin or LEGION_INTAKE_WORKER_BIN"
      ;;
    *)
      # Treat any other worker value as a command path/name with the standard
      # Legion runner contract: `run --sandbox ... --task ... --repo ...`.
      worker_bin="${worker_bin:-${LEGION_INTAKE_WORKER_BIN:-$worker}}"
      worker="custom"
      default_model=""
      untrusted_flag=""
      ;;
  esac

  if [[ "$worker_bin" != */* ]]; then
    worker_bin="$(command -v "$worker_bin" 2>/dev/null || true)"
  fi
  [[ -x "$worker_bin" ]] || die "Legion intake worker not found at $worker_bin"
}

run_worker() {
  local sandbox="$1" task_text="$2"
  local -a argv
  argv=(run --sandbox "$sandbox")
  [[ -n "$archetype" ]] && argv+=(--archetype "$archetype")
  [[ -n "$model" ]] && argv+=(--model "$model")
  argv+=(--task "$task_text" --repo "$PWD")
  [[ -n "$untrusted_flag" ]] && argv+=("$untrusted_flag")
  agent "${argv[@]}"
}

mode="${1:-}"; [[ -n "$mode" ]] || usage; shift || true
issue=""; repo=""; model=""; archetype=""; requested_worker=""; requested_worker_bin=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --issue) issue="$2"; shift 2 ;;
    --repo) repo="$2"; shift 2 ;;
    --archetype) archetype="$2"; shift 2 ;;
    --model) model="$2"; shift 2 ;;
    --worker|--executor) requested_worker="$2"; shift 2 ;;
    --worker-bin|--executor-bin) requested_worker_bin="$2"; shift 2 ;;
    *) usage ;;
  esac
done
[[ "$mode" == "explore" || "$mode" == "implement" ]] || usage
[[ "$issue" =~ ^[0-9]+$ ]] || die "--issue must be a number"
[[ -n "$repo" ]] || die "--repo OWNER/REPO required"
command -v "$GH" >/dev/null 2>&1 || die "gh required. Install gh and run: gh auth login"
command -v jq >/dev/null 2>&1 || die "jq required"
resolve_worker "$requested_worker" "$requested_worker_bin"
model="${model:-${LEGION_INTAKE_MODEL:-$default_model}}"
"$GH" auth status >/dev/null 2>&1 || die "gh not authenticated. Run: gh auth login"
git rev-parse --is-inside-work-tree >/dev/null 2>&1 || die "run from a checked-out git repo"

issue_json="$("$GH" issue view "$issue" --repo "$repo" --json title,body)"
title="$(jq -r '.title' <<<"$issue_json")"
body="$(jq -r '.body // ""' <<<"$issue_json")"
prompt="$(jq -rn --arg n "$issue" --arg t "$title" --arg b "$body" '
  "GitHub issue #\($n)\n\nTitle: \($t)\n\nBody:\n\($b)"')"
model="${model:-${LEGION_INTAKE_MODEL:-$default_model}}"
archetype="${archetype:-${LEGION_INTAKE_ARCHETYPE:-}}"
if [[ -z "$model" && -z "$archetype" ]]; then
  case "$mode" in
    explore) archetype="${LEGION_INTAKE_EXPLORE_ARCHETYPE:-second-opinion-review}" ;;
    implement) archetype="${LEGION_INTAKE_IMPLEMENT_ARCHETYPE:-implement-feature}" ;;
  esac
fi
task="$prompt"
tag="🤖 legion-intake $mode"

# The agent is prompted with USER-CONTROLLED issue text, so a prompt injection
# could try to read tokens from the environment and echo them into its output
# (which we post back to the issue/PR). Run the worker with GitHub + common
# provider secrets scrubbed from its environment. Workers should authenticate via
# their own local store or a mounted auth file, while `gh` posting below keeps
# GH_TOKEN in this parent shell.
agent() {
  env \
    -u GH_TOKEN -u GITHUB_TOKEN \
    -u LEGION_INTAKE_AUTH_JSON -u CODEX_AUTH -u OPENAI_API_KEY \
    -u ANTHROPIC_API_KEY -u ANTHROPIC_AUTH_TOKEN \
    -u CURSOR_API_KEY -u CURSOR_AUTH_TOKEN \
    "$worker_bin" "$@"
}

if [[ "$mode" == "explore" ]]; then
  task="$task"$'\n\n'"Return: a short assessment — root cause if visible, the files involved, and whether this is safe to auto-implement (yes/no) with one-line reasoning."
  set +e
  result="$(run_worker read-only "$task")"
  rc=$?
  set -e
  summary="$(last_message "$result")"
  [[ "$rc" -eq 0 ]] || summary="${summary:-worker failed}"
  comment_issue "$issue" "$repo" "$tag" "$summary"
  exit 0
fi

set +e
result="$(run_worker workspace-write "$task")"
rc=$?
set -e
status="$(jq -r '.status // "failed"' <<<"$result" 2>/dev/null || echo failed)"
diff="$(jq -r '.diff_path // empty' <<<"$result" 2>/dev/null || true)"
summary="$(last_message "$result")"
if [[ "$rc" -ne 0 || "$status" != "ok" || -z "$diff" || ! -s "$diff" ]]; then
  why="worker status=$status"
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
