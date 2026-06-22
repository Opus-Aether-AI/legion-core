#!/usr/bin/env bash
# Shared setup/teardown for legion-delegate disposable worktrees/sandboxes.

sandbox_log() {
  [[ "${LEGION_SANDBOX_QUIET:-0}" == "1" ]] && return 0
  printf 'sandbox setup: %s\n' "$*" >&2
}

sandbox_warn() {
  [[ "${LEGION_SANDBOX_QUIET:-0}" == "1" ]] && return 0
  printf 'sandbox setup: warning: %s\n' "$*" >&2
}

sandbox_config_json() {
  local main_repo_dir="$1" cfg="$main_repo_dir/.legion/sandbox.json" json
  if [[ ! -f "$cfg" ]]; then
    printf '{}'
    return 0
  fi
  if json="$(jq -c 'if type == "object" then . else {} end' "$cfg" 2>/dev/null)"; then
    printf '%s' "$json"
  else
    sandbox_warn "invalid .legion/sandbox.json; ignoring config"
    printf '{}'
  fi
}

sandbox_json_string() {
  local json="$1" key="$2"
  jq -r --arg key "$key" 'if .[$key] | type == "string" then .[$key] else empty end' <<<"$json" 2>/dev/null || true
}

sandbox_copy_paths() {
  local json="$1"
  jq -r '.copy // [] | if type == "array" then .[] | select(type == "string") else empty end' <<<"$json" 2>/dev/null || true
}

sandbox_valid_relative_path() {
  local path="$1"
  [[ -n "$path" ]] || return 1
  [[ "$path" != "." ]] || return 1
  [[ "$path" != /* ]] || return 1
  case "$path" in
    *../*|../*|*/..) return 1 ;;
  esac
  return 0
}

sandbox_git_exclude_path() {
  local worktree_dir="$1" path="$2" exclude
  exclude="$(git -C "$worktree_dir" rev-parse --git-path info/exclude 2>/dev/null || true)"
  [[ -n "$exclude" ]] || return 0
  mkdir -p "$(dirname "$exclude")" 2>/dev/null || return 0
  grep -qxF "$path" "$exclude" 2>/dev/null || printf '%s\n' "$path" >>"$exclude" 2>/dev/null || true
}

sandbox_detect_install() {
  local worktree_dir="$1"
  if [[ -f "$worktree_dir/bun.lockb" || -f "$worktree_dir/bun.lock" ]]; then
    printf 'bun install'
  elif [[ -f "$worktree_dir/pnpm-lock.yaml" ]]; then
    printf 'pnpm install'
  elif [[ -f "$worktree_dir/yarn.lock" ]]; then
    printf 'yarn install'
  elif [[ -f "$worktree_dir/package-lock.json" ]]; then
    printf 'npm install'
  fi
}

sandbox_run_install() {
  local worktree_dir="$1" install_cmd="$2"
  if [[ -z "$install_cmd" ]]; then
    sandbox_log "install skipped (no .install and no supported lockfile)"
    return 0
  fi
  sandbox_log "install: $install_cmd"
  if (cd "$worktree_dir" && bash -c "$install_cmd"); then
    return 0
  fi
  sandbox_warn "install failed; continuing"
  return 0
}

sandbox_copy_credentials() {
  local worktree_dir="$1" main_repo_dir="$2" untrusted="$3" json="$4"
  local paths=() rel src dest
  while IFS= read -r rel; do
    [[ -n "$rel" ]] && paths+=("$rel")
  done < <(sandbox_copy_paths "$json")
  [[ "${#paths[@]}" -gt 0 ]] || return 0

  if [[ "$untrusted" == "1" ]]; then
    sandbox_log "creds skipped (untrusted run)"
    return 0
  fi

  for rel in "${paths[@]}"; do
    if ! sandbox_valid_relative_path "$rel"; then
      sandbox_warn "copy path skipped (not a safe relative path): $rel"
      continue
    fi
    src="$main_repo_dir/$rel"
    dest="$worktree_dir/$rel"
    if [[ ! -e "$src" ]]; then
      sandbox_warn "copy path missing: $rel"
      continue
    fi
    mkdir -p "$(dirname "$dest")" || {
      sandbox_warn "copy parent could not be created: $rel"
      continue
    }
    rm -rf "$dest"
    if cp -a "$src" "$dest"; then
      sandbox_git_exclude_path "$worktree_dir" "$rel"
      sandbox_log "copied creds: $rel"
    else
      sandbox_warn "copy failed: $rel"
    fi
  done
  return 0
}

sandbox_start_dev() {
  local worktree_dir="$1" dev_cmd="$2" artifact_dir pid pgid current_pgid record log
  [[ -n "$dev_cmd" ]] || return 0
  artifact_dir="${LEGION_SANDBOX_ARTIFACT_DIR:-$worktree_dir/.legion}"
  mkdir -p "$artifact_dir" || {
    sandbox_warn "could not create dev artifact dir; skipping dev server"
    return 0
  }
  record="$artifact_dir/sandbox-dev.json"
  log="$artifact_dir/sandbox-dev.log"

  (
    cd "$worktree_dir" || exit 1
    if command -v setsid >/dev/null 2>&1; then
      exec setsid bash -c "$dev_cmd"
    fi
    exec bash -c "$dev_cmd"
  ) >"$log" 2>&1 &
  pid=$!
  sleep 0.1
  pgid="$(ps -o pgid= -p "$pid" 2>/dev/null | tr -d ' ' || true)"
  current_pgid="$(ps -o pgid= -p $$ 2>/dev/null | tr -d ' ' || true)"
  jq -cn --argjson pid "$pid" --arg pgid "$pgid" --arg current_pgid "$current_pgid" \
    --arg cmd "$dev_cmd" --arg log "$log" \
    '{pid:$pid, pgid:(if $pgid == "" then null else ($pgid|tonumber) end),
      parent_pgid:(if $current_pgid == "" then null else ($current_pgid|tonumber) end),
      command:$cmd, log:$log}' >"$record" 2>/dev/null || true
  sandbox_log "dev server started pid=$pid (parallel worktrees may clash on a fixed port)"
  printf '%s' "$pid"
  return 0
}

# sandbox_setup <worktree_dir> <main_repo_dir> <untrusted:0|1>
# Prints the dev server PID on stdout when one was started; otherwise prints nothing.
sandbox_setup() {
  local worktree_dir="$1" main_repo_dir="$2" untrusted="${3:-0}" json install_cmd dev_cmd
  json="$(sandbox_config_json "$main_repo_dir")"
  install_cmd="$(sandbox_json_string "$json" install)"
  [[ -n "$install_cmd" ]] || install_cmd="$(sandbox_detect_install "$worktree_dir")"
  sandbox_run_install "$worktree_dir" "$install_cmd"
  sandbox_copy_credentials "$worktree_dir" "$main_repo_dir" "$untrusted" "$json"
  dev_cmd="$(sandbox_json_string "$json" dev)"
  sandbox_start_dev "$worktree_dir" "$dev_cmd"
  return 0
}

# sandbox_teardown <dev_pid>
sandbox_teardown() {
  local dev_pid="${1:-}" pgid current_pgid
  [[ -n "$dev_pid" && "$dev_pid" =~ ^[0-9]+$ ]] || return 0
  kill -0 "$dev_pid" 2>/dev/null || return 0
  pgid="$(ps -o pgid= -p "$dev_pid" 2>/dev/null | tr -d ' ' || true)"
  current_pgid="$(ps -o pgid= -p $$ 2>/dev/null | tr -d ' ' || true)"
  if [[ -n "$pgid" && "$pgid" != "$current_pgid" ]]; then
    kill -TERM "-$pgid" 2>/dev/null || true
  fi
  kill -TERM "$dev_pid" 2>/dev/null || true
  sleep 0.2
  if kill -0 "$dev_pid" 2>/dev/null; then
    if [[ -n "$pgid" && "$pgid" != "$current_pgid" ]]; then
      kill -KILL "-$pgid" 2>/dev/null || true
    fi
    kill -KILL "$dev_pid" 2>/dev/null || true
  fi
  return 0
}
