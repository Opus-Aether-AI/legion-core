#!/usr/bin/env bash
# Shared diff-contract runner for the Pi and Hermes coding CLIs.  The provider
# processes never receive the caller's repository: each run gets a disposable
# worktree and returns only an artifact-backed patch.
set -euo pipefail

_self_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$_self_dir/lib/model-config.sh"
# shellcheck disable=SC1091
source "$_self_dir/lib/executor-context.sh"
# shellcheck disable=SC1091
# shellcheck source=lib/run-id.sh
source "$_self_dir/lib/run-id.sh"
# shellcheck disable=SC1091
source "$_self_dir/lib/task-scan.sh"
_state_lib="$_self_dir/../../legion-observability/scripts/lib/state.sh"
# shellcheck disable=SC1090
[[ -f "$_state_lib" ]] && source "$_state_lib"

ADAPTER_KIND="${LEGION_ADAPTER_KIND:?LEGION_ADAPTER_KIND must be pi or hermes}"
case "$ADAPTER_KIND" in pi|hermes) ;; *) printf 'invalid Legion adapter kind\n' >&2; exit 2 ;; esac
ADAPTER="legion-$ADAPTER_KIND"
PROVIDER_BIN="${PI_BIN:-pi}"
[[ "$ADAPTER_KIND" == hermes ]] && PROVIDER_BIN="${HERMES_BIN:-hermes}"
RUN_ID="" CHILD_PID="" KEEP=0 WT="" WT_RECORD="" BRANCH="" REPO="" ART=""
WT_CREATED=0 BRANCH_CREATED=0
BROKER_PID="" BROKER_SOCKET_DIR="" BROKER_SOCKET="" BROKER_TOKEN="" BROKER_ROOT="" BROKER_RC=0
CONTROL_EMPTY_DIR="" SANITIZED_PROVIDER_PATH=""
SUPERVISOR_DENY_CANARY="" SUPERVISOR_ALLOW_CANARY=""
TARGET_SUPERVISOR_DENY_CANARY="" TARGET_SUPERVISOR_ALLOW_CANARY=""
WT_GIT_FILE_ID="" BASE_SHA="" SAFE_GIT_DIR="" COMMON_GIT_OBJECTS=""
PROVIDER_OUT="" PROVIDER_ERR="" PROVIDER_USAGE=""
PROVIDER_OUT_ID="" PROVIDER_ERR_ID="" PROVIDER_USAGE_ID=""
FS_SANDBOX_BIN="" FS_SANDBOX_KIND=""
PRIVATE_RUNTIME_DIR="" PI_PRIVATE_AGENT_DIR="" HERMES_PRIVATE_HOME=""
FS_SANDBOX_COMMAND=()
DELEGATE_BLOCK_PATHS=()

die() { printf '%s: %s\n' "$ADAPTER" "$*" >&2; exit 2; }
note() { [[ "${QUIET:-0}" == 1 ]] || printf '%s\n' "$*" >&2; }
_run_id() { legion_new_run_id; }

with_git_worktree_lock() {
  local repo="$1"
  shift
  if declare -F legion_with_git_worktree_lock >/dev/null 2>&1; then
    legion_with_git_worktree_lock "$repo" "$@"
  else
    return 1
  fi
}

remove_owned_worktree_unlocked() {
  git -C "$REPO" worktree remove --force "$WT" || return 1
  [[ "$BRANCH_CREATED" != 1 || -z "$BRANCH" ]] || git -C "$REPO" branch -D "$BRANCH" || return 1
  git -C "$REPO" worktree prune
}

cleanup_worktree() {
  stop_handoff_broker
  if [[ -n "$BROKER_SOCKET_DIR" ]]; then
    rm -rf "$BROKER_SOCKET_DIR"
    BROKER_SOCKET_DIR=""
  fi
  if [[ -n "$PRIVATE_RUNTIME_DIR" ]]; then
    rm -rf "$PRIVATE_RUNTIME_DIR"
    PRIVATE_RUNTIME_DIR=""
  fi
  [[ "$KEEP" == 1 || "$WT_CREATED" != 1 || -z "$WT" || -z "$REPO" ]] && return 0
  if with_git_worktree_lock "$REPO" remove_owned_worktree_unlocked >/dev/null 2>&1; then
    WT_CREATED=0 BRANCH_CREATED=0
  else
    note "warning: could not acquire the shared Git worktree lock for cleanup; retained $WT"
  fi
}
stop_child() {
  [[ -n "$CHILD_PID" ]] || return 0
  kill -TERM "$CHILD_PID" 2>/dev/null || true
  local i=0
  while kill -0 "$CHILD_PID" 2>/dev/null && (( i < 140 )); do sleep 0.05; i=$((i + 1)); done
  kill -KILL "$CHILD_PID" 2>/dev/null || true
  wait "$CHILD_PID" 2>/dev/null || true
  CHILD_PID=""
}
stop_handoff_broker() {
  [[ -n "$BROKER_PID" ]] || return 0
  kill -TERM "$BROKER_PID" 2>/dev/null || true
  local i=0
  while kill -0 "$BROKER_PID" 2>/dev/null && (( i < 200 )); do sleep 0.05; i=$((i + 1)); done
  kill -KILL "$BROKER_PID" 2>/dev/null || true
  set +e
  wait "$BROKER_PID" 2>/dev/null
  BROKER_RC=$?
  set -e
  BROKER_PID=""
}
on_signal() {
  trap - INT TERM HUP
  stop_child
  [[ -z "$RUN_ID" || -z "$ART" ]] || write_state failed
  exit 143
}
trap 'declare -F legion_terminalize_adopted_run_on_exit >/dev/null 2>&1 && legion_terminalize_adopted_run_on_exit; cleanup_worktree' EXIT
trap on_signal INT TERM HUP

resolve_state() {
  if declare -F legion_resolve_state >/dev/null 2>&1; then legion_resolve_state "$1"; else
    export LEGION_STATE_ROOT="${LEGION_STATE_ROOT:-$HOME/.legion/projects/default}"
    export LEGION_TELEMETRY_DIR="${LEGION_TELEMETRY_DIR:-$LEGION_STATE_ROOT/spans}"
  fi
}
write_state() {
  local phase="$1"
  [[ -n "${PRESET_RUN_ID:-}" ]] || return 0
  legion_write_adapter_run_state "$phase" "$RUN_ID" "$REPO" "$ART" "$WT_RECORD" "$BRANCH" "$MODEL" "$SANDBOX" "$BASE" "$ARCHETYPE" "${THINKING:-}"
}
emit_span() {
  local status="$1" duration="$2" cost="$3" usage="$4" task="$5" artifacts="$6"
  local trace_bin="$_self_dir/../../legion-observability/bin/legion-trace"
  if [[ ! -x "$trace_bin" ]]; then
    note "warning: canonical legion-trace emitter is unavailable; span was not emitted"
    return 0
  fi
  if ! (cd "$REPO" && "$trace_bin" emit \
      --executor "$ADAPTER_KIND" --model "$MODEL" --status "$status" \
      --run-id "$RUN_ID" --trace-id "${LEGION_TRACE_ID:-$RUN_ID}" \
      --parent-id "${LEGION_PARENT_ID:-}" --archetype "$ARCHETYPE" \
      --duration-ms "$duration" --cost "$cost" --task "$task" \
      --tokens "$usage" --artifacts "$artifacts") \
      > /dev/null 2>>"$ART/telemetry.err"; then
    note "warning: canonical Legion span emission failed; inspect $ART/telemetry.err"
  fi
}

pi_usage() {
  local file="$1"
  [[ -s "$file" ]] || { printf '{}'; return 0; }
  jq -s -c '
    ([.[] | select(.type == "message_end" and .message.role == "assistant") | .message]
      + [.[] | select(.type == "compaction_end" and .aborted == false and .result.usage != null) | .result.usage]) as $receipts
    | reduce $receipts[] as $receipt
        ({input_tokens:0,cached_input_tokens:0,output_tokens:0,reasoning_output_tokens:0,cache_creation_input_tokens:0};
         ($receipt.usage // $receipt) as $usage
         | .input_tokens += $usage.input
         | .cached_input_tokens += $usage.cacheRead
         | .reasoning_output_tokens += ($usage.reasoning // 0)
         | .output_tokens += ($usage.output - ($usage.reasoning // 0))
         | .cache_creation_input_tokens += $usage.cacheWrite)' \
    "$file" 2>/dev/null || printf '{}'
}
pi_cost() {
  local file="$1"
  [[ -s "$file" ]] || { printf 0; return 0; }
  jq -s -r '
    ([.[] | select(.type == "message_end" and .message.role == "assistant") | .message.usage.cost.total]
      + [.[] | select(.type == "compaction_end" and .aborted == false and .result.usage != null) | .result.usage.cost.total])
    | add // 0' \
    "$file" 2>/dev/null || printf 0
}
pi_result() {
  local file="$1"
  jq -s -r '
    ([.[] | select(.type == "agent_end")] | last) as $end
    | if $end == null then empty else
        ([$end.messages[]? | select(.role == "assistant")] | last) as $m
        | ($m.content // "") | if type=="string" then . else [ .[]? | select(.type=="text") | .text ] | join("") end
      end' "$file" 2>/dev/null || true
}
pi_terminal_ok() {
  jq -s -e '
    def nn: type == "number" and . >= 0;
    def nni: nn and floor == .;
    def valid_usage:
      type == "object"
      and (.input | nni)
      and (.output | nni)
      and (.cacheRead | nni)
      and (.cacheWrite | nni)
      and ((.reasoning == null) or (.reasoning | nni))
      and ((.reasoning // 0) <= .output)
      and (.totalTokens | nni)
      and .totalTokens == (.input + .output + .cacheRead + .cacheWrite)
      and (.cost | type == "object")
      and (.cost.input | nn)
      and (.cost.output | nn)
      and (.cost.cacheRead | nn)
      and (.cost.cacheWrite | nn)
      and (.cost.total | nn);
    ([.[] | select(.type == "agent_end")] | last) as $end
    | [$end.messages[]? | select(.role == "assistant")] as $messages
    | ($messages | last) as $final
    | [.[] | select(.type == "message_end" and .message.role == "assistant") | .message] as $calls
    | [.[] | select(.type == "compaction_end" and .aborted == false and .result.usage != null) | .result.usage] as $compactions
    | all(.[]; type == "object")
      and (all(.[]; .type? != "error"))
      and ($end | type == "object")
      and ($end.willRetry == false)
      and ($messages | length > 0)
      and ($calls | length > 0)
      and all($calls[];
        (.provider | type == "string" and length > 0)
        and (.model | type == "string" and length > 0)
        and (.stopReason | IN("stop", "length", "toolUse", "error", "aborted"))
        and (.usage | valid_usage))
      and all($compactions[]; valid_usage)
      and ($final.stopReason == "stop" or $final.stopReason == "length")
  ' "$1" >/dev/null 2>&1
}
pi_actual_model() {
  jq -s -r '
    ([.[] | select(.type == "agent_end")] | last) as $end
    | ([$end.messages[]? | select(.role == "assistant")] | last) as $message
    | ($message.provider // "") as $provider
    | (if (($message.responseModel // "") | length) > 0 then $message.responseModel else ($message.model // "") end) as $model
    | if $model == "" then empty
      elif $provider == "" or ($model | startswith($provider + "/")) then $model
      else $provider + "/" + $model end' "$1" 2>/dev/null || true
}
hermes_usage() {
  local file="$1"
  [[ -s "$file" ]] || { printf '{}'; return 0; }
  jq -c '{input_tokens:.input_tokens,
          cached_input_tokens:.cache_read_tokens,
          output_tokens:(.output_tokens - .reasoning_tokens),
          reasoning_output_tokens:.reasoning_tokens,
          cache_creation_input_tokens:.cache_write_tokens}' "$file" 2>/dev/null || printf '{}'
}
hermes_cost() {
  local file="$1"
  [[ -s "$file" ]] || { printf 0; return 0; }
  jq -r '.estimated_cost_usd' "$file" 2>/dev/null || printf 0
}

# The span schema requires cost_usd to be a non-null number, so a missing or
# malformed cost necessarily becomes 0 -- which is indistinguishable from
# genuinely free execution. Hermes already reports cost_status and cost_source
# (the terminal validator above checks both), so carry them alongside the number
# and let a reader tell "free" from "we do not know".
hermes_cost_provenance() {
  local file="$1"
  if [[ ! -s "$file" ]]; then
    printf '{"cost_status":"unknown","cost_source":"none"}'
    return 0
  fi
  jq -c '{cost_status: (.cost_status // "unknown"),
          cost_source: (.cost_source // "none")}' "$file" 2>/dev/null \
    || printf '{"cost_status":"unknown","cost_source":"none"}'
}
hermes_result() {
  cat "$1"
}
hermes_terminal_ok() {
  local out_file="$1" usage_file="$2"
  grep -q '[^[:space:]]' "$out_file" || return 1
  jq -e '
    def nn: type == "number" and . >= 0;
    def nni: nn and floor == .;
    type == "object"
    and .completed == true
    and .failed == false
    and (.input_tokens | nni)
    and (.output_tokens | nni)
    and (.cache_read_tokens | nni)
    and (.cache_write_tokens | nni)
    and (.reasoning_tokens | nni)
    and .reasoning_tokens <= .output_tokens
    and (.total_tokens | nni)
    and .total_tokens == (.input_tokens + .output_tokens + .cache_read_tokens + .cache_write_tokens)
    and (.api_calls | nni and . > 0)
    and (.estimated_cost_usd | nn)
    and (.cost_status | IN("actual", "estimated", "included", "unknown"))
    and (.cost_source | IN("provider_cost_api", "provider_generation_api", "provider_models_api", "official_docs_snapshot", "user_override", "custom_contract", "none"))
    and (.model | type == "string" and length > 0)
    and (.provider | type == "string" and length > 0)
    and (.session_id | type == "string" and length > 0)
    and ((.service_tier == null) or (.service_tier | type == "string"))
    and (has("failure") | not)
  ' "$usage_file" >/dev/null 2>&1
}
hermes_actual_model() { jq -r '.model // empty' "$1" 2>/dev/null || true; }
provider_ready() {
  local env_prefix
  env_prefix="$(printf '%s' "$ADAPTER_KIND" | tr '[:lower:]' '[:upper:]')"
  PROVIDER_BIN="$(command -v "$PROVIDER_BIN" 2>/dev/null || true)"
  [[ -n "$PROVIDER_BIN" ]] || die "$ADAPTER_KIND CLI not found. Install it or set ${env_prefix}_BIN to its executable."
  [[ "$MODEL" != "$ADAPTER_KIND-default" ]] || die "no concrete model configured: set ${env_prefix}_MODEL or update ${ADAPTER_KIND}_default in models.toml."
}

prepare_delegate_boundary() {
  local candidate resolved dir path_tail=""
  DELEGATE_BLOCK_PATHS=()
  while IFS= read -r candidate; do
    [[ -n "$candidate" && "$candidate" != "$ART/broker-bin/legion-delegate" ]] || continue
    DELEGATE_BLOCK_PATHS+=("$candidate")
    resolved="$(python3 -c 'import os,sys; print(os.path.realpath(sys.argv[1]))' "$candidate" 2>/dev/null || true)"
    [[ -z "$resolved" || "$resolved" == "$candidate" ]] || DELEGATE_BLOCK_PATHS+=("$resolved")
  done < <(
    type -a -p legion-delegate 2>/dev/null || true
    printf '%s\n' "$_self_dir/../bin/legion-delegate" "$WT/legion-router/bin/legion-delegate" "$WT/legion-router/scripts/delegate.sh"
  )

  IFS=: read -r -a path_entries <<<"$PATH"
  for dir in "${path_entries[@]}"; do
    [[ -n "$dir" ]] || dir=.
    [[ ! -e "$dir/legion-delegate" ]] || continue
    path_tail="${path_tail:+$path_tail:}$dir"
  done
  SANITIZED_PROVIDER_PATH="$ART/broker-bin${path_tail:+:$path_tail}"
}
valid_thinking() { case "$1" in off|minimal|low|medium|high|xhigh|max) return 0;; *) return 1;; esac; }

resolve_fs_sandbox() {
  local requested="${LEGION_FS_SANDBOX_BIN:-}" candidate=""
  if [[ -n "$requested" ]]; then
    if [[ "$requested" == */* ]]; then
      [[ -x "$requested" ]] || die "filesystem sandbox is unavailable or not executable: $requested"
      candidate="$requested"
    else
      candidate="$(command -v "$requested" 2>/dev/null || true)"
      [[ -n "$candidate" ]] || die "filesystem sandbox is unavailable: $requested"
    fi
  elif command -v sandbox-exec >/dev/null 2>&1; then
    candidate="$(command -v sandbox-exec)"
  elif command -v bwrap >/dev/null 2>&1; then
    candidate="$(command -v bwrap)"
  elif command -v bubblewrap >/dev/null 2>&1; then
    candidate="$(command -v bubblewrap)"
  else
    die "no filesystem write sandbox is available (macOS: sandbox-exec; Linux: install bubblewrap/bwrap)"
  fi
  FS_SANDBOX_BIN="$candidate"
  case "$(basename "$candidate")" in
    sandbox-exec) FS_SANDBOX_KIND="sandbox-exec" ;;
    bwrap|bubblewrap) FS_SANDBOX_KIND=bwrap ;;
    *) die "unsupported filesystem sandbox executable: $candidate" ;;
  esac
}

scheme_escape() {
  [[ "$1" != *$'\n'* && "$1" != *$'\r'* ]] || die 'filesystem sandbox path contains a newline'
  printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g'
}

build_fs_sandbox_command() {
  FS_SANDBOX_COMMAND=()
  if [[ "$FS_SANDBOX_KIND" == sandbox-exec ]]; then
    local profile="$ART/filesystem.sb" escaped_wt escaped_tmp escaped_cache escaped_private escaped_out escaped_err escaped_usage escaped_broker escaped_supervisor_deny blocked escaped_blocked
    escaped_wt="$(scheme_escape "$WT")"
    escaped_tmp="$(scheme_escape "$ART/tmp")"
    escaped_cache="$(scheme_escape "$ART/cache")"
    escaped_private="$(scheme_escape "$PRIVATE_RUNTIME_DIR")"
    escaped_out="$(scheme_escape "$PROVIDER_OUT")"
    escaped_err="$(scheme_escape "$PROVIDER_ERR")"
    escaped_usage="$(scheme_escape "$PROVIDER_USAGE")"
    escaped_broker="$(scheme_escape "$BROKER_SOCKET")"
    escaped_supervisor_deny="$(scheme_escape "$SUPERVISOR_DENY_CANARY")"
    printf '%s\n' \
      '(version 1)' \
      '(allow default)' \
      '(deny file-write*)' \
      '(deny signal)' \
      '(deny process-info*)' \
      "(deny file-read* (literal \"$escaped_supervisor_deny\"))" \
      '(deny network-outbound (remote unix-socket))' \
      '(allow network-outbound (remote unix-socket (path-literal "/private/var/run/mDNSResponder")))' \
      "(allow network-outbound (remote unix-socket (path-literal \"$escaped_broker\")))" \
      "(allow file-write* (literal \"/dev/null\") (literal \"/dev/tty\") (subpath \"$escaped_wt\") (subpath \"$escaped_tmp\") (subpath \"$escaped_cache\") (subpath \"$escaped_private\") (literal \"$escaped_out\") (literal \"$escaped_err\") (literal \"$escaped_usage\"))" \
      > "$profile"
    for blocked in "${DELEGATE_BLOCK_PATHS[@]}"; do
      [[ "$blocked" != "$ART/broker-bin/legion-delegate" ]] || continue
      escaped_blocked="$(scheme_escape "$blocked")"
      printf '(deny process-exec (literal "%s"))\n' "$escaped_blocked" >> "$profile"
      # An absolute script can otherwise bypass process-exec by being handed to
      # an interpreter. Hide installed copies outside the generated worktree;
      # worktree files remain readable so a Legion source task can edit them.
      if [[ "$blocked" != "$WT"/* ]]; then
        printf '(deny file-read* (literal "%s"))\n' "$escaped_blocked" >> "$profile"
      fi
    done
    FS_SANDBOX_COMMAND=("$FS_SANDBOX_BIN" -f "$profile")
  else
    FS_SANDBOX_COMMAND=("$FS_SANDBOX_BIN" --die-with-parent --new-session --unshare-pid \
      --ro-bind / / --bind "$WT" "$WT" \
      --bind "$ART/tmp" "$ART/tmp" --bind "$ART/cache" "$ART/cache" \
      --bind "$PRIVATE_RUNTIME_DIR" "$PRIVATE_RUNTIME_DIR" \
      --bind "$PROVIDER_OUT" "$PROVIDER_OUT" --bind "$PROVIDER_ERR" "$PROVIDER_ERR" \
      --bind "$PROVIDER_USAGE" "$PROVIDER_USAGE")
    FS_SANDBOX_COMMAND+=(--tmpfs /run)
    local control_dir
    for control_dir in \
      /var/run "$HOME/.docker/run" "$HOME/.docker/desktop" "$HOME/.local/share/containers" \
      "$HOME/.colima" "$HOME/.orbstack" "$HOME/Library/Containers/com.docker.docker" \
      "$HOME/Library/Group Containers/group.com.docker"; do
      [[ -d "$control_dir" && ! -L "$control_dir" ]] || continue
      FS_SANDBOX_COMMAND+=(--ro-bind "$CONTROL_EMPTY_DIR" "$control_dir")
    done
    local blocked
    for blocked in "${DELEGATE_BLOCK_PATHS[@]}"; do
      [[ -e "$blocked" && "$blocked" != "$ART/broker-bin/legion-delegate" ]] || continue
      FS_SANDBOX_COMMAND+=(--ro-bind "$ART/broker-bin/legion-delegate" "$blocked")
    done
    FS_SANDBOX_COMMAND+=(--proc /proc --chdir "$WT" --)
  fi
}

file_identity() {
  if stat -f '%d:%i' "$1" >/dev/null 2>&1; then stat -f '%d:%i' "$1"; else stat -c '%d:%i' "$1"; fi
}

verify_provider_file() {
  local file="$1" expected="$2"
  [[ -f "$file" && ! -L "$file" && "$(file_identity "$file" 2>/dev/null || true)" == "$expected" ]]
}

prepare_provider_files() {
  PROVIDER_OUT="$ART/$ADAPTER_KIND.out.jsonl"
  PROVIDER_ERR="$ART/$ADAPTER_KIND.err"
  PROVIDER_USAGE="$ART/$ADAPTER_KIND.usage.json"
  : > "$PROVIDER_OUT"
  : > "$PROVIDER_ERR"
  : > "$PROVIDER_USAGE"
  : > "$ART/telemetry.err"
  PROVIDER_OUT_ID="$(file_identity "$PROVIDER_OUT")"
  PROVIDER_ERR_ID="$(file_identity "$PROVIDER_ERR")"
  PROVIDER_USAGE_ID="$(file_identity "$PROVIDER_USAGE")"
}

copy_private_runtime_file() {
  local source="$1" destination="$2" size=""
  [[ -f "$source" && ! -L "$source" ]] || return 0
  if stat -f '%z' "$source" >/dev/null 2>&1; then size="$(stat -f '%z' "$source")"; else size="$(stat -c '%s' "$source")"; fi
  [[ "$size" =~ ^[0-9]+$ && "$size" -le 16777216 ]] || return 0
  mkdir -p "${destination%/*}"
  cp "$source" "$destination"
  chmod 600 "$destination"
}

prepare_private_provider_runtime() {
  local source name
  PRIVATE_RUNTIME_DIR="$(mktemp -d "${TMPDIR:-/tmp}/legion-provider-runtime.XXXXXX")" \
    || die 'unable to allocate private provider runtime'
  chmod 700 "$PRIVATE_RUNTIME_DIR"
  if [[ "$ADAPTER_KIND" == pi ]]; then
    PI_PRIVATE_AGENT_DIR="$PRIVATE_RUNTIME_DIR/pi-agent"
    mkdir -p "$PI_PRIVATE_AGENT_DIR"
    source="${PI_CODING_AGENT_DIR:-$HOME/.pi/agent}"
    for name in auth.json settings.json models.json keybindings.json; do
      copy_private_runtime_file "$source/$name" "$PI_PRIVATE_AGENT_DIR/$name"
    done
  else
    HERMES_PRIVATE_HOME="$PRIVATE_RUNTIME_DIR/hermes"
    mkdir -p "$HERMES_PRIVATE_HOME"
    source="${HERMES_HOME:-$HOME/.hermes}"
    for name in .env auth.json; do
      copy_private_runtime_file "$source/$name" "$HERMES_PRIVATE_HOME/$name"
    done
  fi
}

safe_git() {
  env GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null \
    GIT_OBJECT_DIRECTORY="$SAFE_GIT_DIR/objects" GIT_ALTERNATE_OBJECT_DIRECTORIES="$COMMON_GIT_OBJECTS" \
    GIT_INDEX_FILE="$SAFE_GIT_DIR/index" \
    git --git-dir="$SAFE_GIT_DIR" --work-tree="$WT" "$@"
}

copy_safe_git_setting() {
  local key="$1" pattern="$2" value=""
  value="$(git -C "$REPO" config --get "$key" 2>/dev/null || true)"
  [[ -n "$value" ]] || return 0
  [[ "$value" =~ $pattern ]] || die "unsupported trusted Git setting $key=$value"
  git config --file "$SAFE_GIT_DIR/config" "$key" "$value"
}

trusted_attributes_have_filters() {
  safe_git ls-files --cached --others --exclude-standard -z \
    | safe_git check-attr --stdin -z filter \
    | python3 -c 'import sys
parts = sys.stdin.buffer.read().split(b"\0")
if parts and parts[-1] == b"": parts.pop()
if len(parts) % 3: raise SystemExit(2)
raise SystemExit(any(parts[i + 2] not in (b"unspecified", b"unset") for i in range(0, len(parts), 3)))'
}

reject_unrepresented_attribute_sources() {
  local common_git_dir="$1" worktree_git_dir attributes_file
  worktree_git_dir="$(git -C "$WT" rev-parse --absolute-git-dir 2>/dev/null)" \
    || die 'unable to resolve worktree Git directory for attributes'
  attributes_file="$(git -C "$WT" config --path --get core.attributesFile 2>/dev/null || true)"
  [[ -z "$attributes_file" ]] \
    || die 'Git core.attributesFile is unsupported by isolated diff capture; refusing to change repository semantics'
  for attributes_file in "$worktree_git_dir/info/attributes" "$common_git_dir/info/attributes"; do
    [[ ! -L "$attributes_file" ]] \
      || die 'symlinked Git info/attributes is unsupported by isolated diff capture'
    [[ ! -s "$attributes_file" ]] \
      || die 'Git info/attributes is unsupported by isolated diff capture; refusing to change repository semantics'
  done
}

prepare_trusted_git_metadata() {
  local common_git_dir object_format repository_format=0
  git -C "$WT" rev-parse --absolute-git-dir >/dev/null || die 'unable to resolve trusted worktree Git metadata'
  BASE_SHA="$(git -C "$WT" rev-parse --verify 'HEAD^{commit}')" || die 'unable to resolve worktree base commit'
  object_format="$(git -C "$REPO" rev-parse --show-object-format 2>/dev/null || printf sha1)"
  case "$object_format" in sha1) ;; sha256) repository_format=1;; *) die "unsupported Git object format: $object_format";; esac
  common_git_dir="$(git -C "$REPO" rev-parse --git-common-dir)" || die 'unable to resolve common Git metadata'
  if [[ "$common_git_dir" == /* ]]; then
    common_git_dir="$(cd "$common_git_dir" 2>/dev/null && pwd -P)" || die 'unable to canonicalize common Git metadata'
  else
    common_git_dir="$(cd "$REPO/$common_git_dir" 2>/dev/null && pwd -P)" || die 'unable to canonicalize common Git metadata'
  fi
  COMMON_GIT_OBJECTS="$common_git_dir/objects"
  [[ "$COMMON_GIT_OBJECTS" != *:* && "$COMMON_GIT_OBJECTS" != *$'\n'* ]] \
    || die 'common Git object path is unsafe for isolated diff capture'
  [[ -f "$WT/.git" && ! -L "$WT/.git" ]] || die 'worktree .git pointer is not a regular file'
  reject_unrepresented_attribute_sources "$common_git_dir"
  WT_GIT_FILE_ID="$(file_identity "$WT/.git")"
  cp "$WT/.git" "$ART/worktree.git-pointer"
  SAFE_GIT_DIR="$ART/safe-git"
  mkdir -p "$SAFE_GIT_DIR/objects/info" "$SAFE_GIT_DIR/objects/pack" "$SAFE_GIT_DIR/refs/heads"
  printf '%s\n' \
    '[core]' \
    "  repositoryformatversion = $repository_format" \
    '  bare = false' \
    '  hooksPath = /dev/null' \
    '  fsmonitor = false' \
    > "$SAFE_GIT_DIR/config"
  if [[ "$object_format" == sha256 ]]; then
    printf '%s\n' '[extensions]' '  objectFormat = sha256' >> "$SAFE_GIT_DIR/config"
  fi
  copy_safe_git_setting core.autocrlf '^(true|false|input)$'
  copy_safe_git_setting core.eol '^(lf|crlf|native)$'
  copy_safe_git_setting core.safecrlf '^(true|false|warn)$'
  copy_safe_git_setting core.symlinks '^(true|false)$'
  copy_safe_git_setting core.ignorecase '^(true|false)$'
  copy_safe_git_setting core.precomposeunicode '^(true|false)$'
  copy_safe_git_setting core.filemode '^(true|false)$'
  printf 'ref: refs/heads/legion-safe\n' > "$SAFE_GIT_DIR/HEAD"
  safe_git read-tree "$BASE_SHA" \
    || die 'unable to initialize isolated diff index'
  trusted_attributes_have_filters \
    || die 'Git clean-filter attributes are unsupported by isolated diff capture; refusing to change repository semantics'
}

capture_trusted_diff() {
  local diff="$1"
  [[ -f "$WT/.git" && ! -L "$WT/.git" ]] || return 1
  [[ "$(file_identity "$WT/.git" 2>/dev/null || true)" == "$WT_GIT_FILE_ID" ]] || return 1
  cmp -s "$WT/.git" "$ART/worktree.git-pointer" || return 1
  trusted_attributes_have_filters || return 1
  safe_git add -A || return 1
  safe_git diff --cached --binary --no-ext-diff --no-textconv "$BASE_SHA" > "$diff"
}

start_handoff_broker() {
  local helper="$_self_dir/legion-handoff-broker.py" delegate="$_self_dir/../bin/legion-delegate" supervisor="$_self_dir/legion-process-supervisor.py" i supervisor_nonce
  [[ -x "$helper" && -x "$delegate" && -x "$supervisor" ]] || die 'trusted Legion handoff broker is unavailable'
  BROKER_RC=0
  BROKER_SOCKET_DIR="$(mktemp -d "${TMPDIR:-/tmp}/legion-broker.XXXXXX")" || die 'unable to allocate handoff broker socket directory'
  BROKER_SOCKET_DIR="$(cd "$BROKER_SOCKET_DIR" && pwd -P)" || die 'unable to canonicalize handoff broker socket directory'
  BROKER_SOCKET="$BROKER_SOCKET_DIR/broker.sock"
  BROKER_TOKEN="$(python3 -c 'import secrets; print(secrets.token_hex(32))')"
  BROKER_ROOT="$BROKER_SOCKET_DIR/runtime-root"
  CONTROL_EMPTY_DIR="$BROKER_SOCKET_DIR/control-empty"
  supervisor_nonce="$(python3 -c 'import secrets; print(secrets.token_hex(64))')"
  SUPERVISOR_DENY_CANARY="$BROKER_SOCKET_DIR/${supervisor_nonce:0:32}"
  SUPERVISOR_ALLOW_CANARY="$BROKER_SOCKET_DIR/${supervisor_nonce:32:32}"
  TARGET_SUPERVISOR_DENY_CANARY="$BROKER_SOCKET_DIR/${supervisor_nonce:64:32}"
  TARGET_SUPERVISOR_ALLOW_CANARY="$BROKER_SOCKET_DIR/${supervisor_nonce:96:32}"
  : > "$SUPERVISOR_DENY_CANARY"
  : > "$SUPERVISOR_ALLOW_CANARY"
  : > "$TARGET_SUPERVISOR_DENY_CANARY"
  : > "$TARGET_SUPERVISOR_ALLOW_CANARY"
  chmod 400 "$SUPERVISOR_DENY_CANARY" "$SUPERVISOR_ALLOW_CANARY" \
    "$TARGET_SUPERVISOR_DENY_CANARY" "$TARGET_SUPERVISOR_ALLOW_CANARY"
  mkdir -m 555 "$CONTROL_EMPTY_DIR"
  mkdir -p "$ART/broker-bin"
  cp "$helper" "$ART/broker-bin/legion-delegate"
  chmod 755 "$ART/broker-bin/legion-delegate"
  prepare_delegate_boundary
  python3 "$helper" serve --socket "$BROKER_SOCKET" --token "$BROKER_TOKEN" \
    --delegate "$delegate" --source-repo "$REPO" --broker-root "$BROKER_ROOT" --base-sha "$BASE_SHA" \
    --sandbox-bin "$FS_SANDBOX_BIN" --sandbox-kind "$FS_SANDBOX_KIND" \
    --supervisor "$supervisor" \
    --supervisor-deny-canary "$TARGET_SUPERVISOR_DENY_CANARY" \
    --supervisor-allow-canary "$TARGET_SUPERVISOR_ALLOW_CANARY" \
    --telemetry-dir "${LEGION_TELEMETRY_DIR:-}" --expected-parent "$RUN_ID" \
    > "$ART/broker.out" 2> "$ART/broker.err" &
  BROKER_PID=$!
  i=0
  while (( i < 100 )); do
    [[ -S "$BROKER_SOCKET" ]] && return 0
    kill -0 "$BROKER_PID" 2>/dev/null || break
    sleep 0.05
    i=$((i + 1))
  done
  stop_handoff_broker
  die "handoff broker failed to start; inspect $ART/broker.err"
}

prepare_runtime_roots() {
  local root="$REPO/.legion" candidate
  for candidate in "$root" "$root/runs" "$root/worktrees" "$ART" "$WT" "$root/.gitignore"; do
    [[ ! -L "$candidate" ]] || die "refusing symlinked Legion runtime path: $candidate"
  done
  [[ ! -e "$ART" || -d "$ART" ]] || die "refusing non-directory Legion artifact path: $ART"
  if [[ -d "$ART" && -n "$(find "$ART" -mindepth 1 -maxdepth 1 -print -quit 2>/dev/null)" ]]; then
    die "refusing non-empty Legion artifact directory: $ART"
  fi
  mkdir -p "$ART" "$root/worktrees" "$ART/tmp" "$ART/cache"
  if [[ ! -e "$root/.gitignore" ]]; then
    printf '*\n' > "$root/.gitignore"
  elif ! grep -qxF '*' "$root/.gitignore"; then
    printf '\n*\n' >> "$root/.gitignore"
  fi
}

write_worktree_ownership() {
  local record="$ART/worktree-owner.json" temp="$ART/.worktree-owner.tmp.$$"
  jq -cn --arg schema 'legion.worktree-owner.v1' --arg run "$RUN_ID" \
    --arg executor "$ADAPTER_KIND" --arg repo "$REPO" --arg worktree "$WT" \
    --arg branch "$BRANCH" --arg base "$BASE_SHA" \
    '{schema:$schema,run_id:$run,executor:$executor,repo:$repo,worktree:$worktree,branch:$branch,base_sha:$base}' \
    > "$temp" || return 1
  chmod 600 "$temp" || return 1
  mv -f "$temp" "$record"
}

run_provider() {
  local out="$1" err="$2"; shift 2
  build_fs_sandbox_command
  local supervisor="$_self_dir/legion-process-supervisor.py"
  [[ -x "$supervisor" ]] || die 'portable Legion process supervisor is unavailable'
  local -a invocation=(env \
    -u DOCKER_HOST -u CONTAINER_HOST -u BUILDKIT_HOST -u SSH_AUTH_SOCK -u KUBECONFIG -u CONTAINERD_ADDRESS \
    "TMPDIR=$ART/tmp" "TMP=$ART/tmp" "TEMP=$ART/tmp" \
    "XDG_CACHE_HOME=$ART/cache" "PYTHONDONTWRITEBYTECODE=1" \
    "PATH=$SANITIZED_PROVIDER_PATH" \
    "LEGION_HANDOFF_BROKER_SOCKET=$BROKER_SOCKET" "LEGION_HANDOFF_BROKER_TOKEN=$BROKER_TOKEN" \
    "HERMES_ENABLE_PROJECT_PLUGINS=0" "HERMES_ACCEPT_HOOKS=0")
  if [[ "$ADAPTER_KIND" == pi ]]; then
    invocation+=("PI_CODING_AGENT_DIR=$PI_PRIVATE_AGENT_DIR")
  else
    invocation+=("HERMES_HOME=$HERMES_PRIVATE_HOME")
  fi
  invocation+=("${FS_SANDBOX_COMMAND[@]}" "$@")
  local -a supervisor_args=(python3 "$supervisor" --cwd "$WT")
  if [[ "$FS_SANDBOX_KIND" == sandbox-exec ]]; then
    supervisor_args+=(--darwin-sandbox-deny-canary "$SUPERVISOR_DENY_CANARY" \
      --darwin-sandbox-allow-canary "$SUPERVISOR_ALLOW_CANARY")
  fi
  supervisor_args+=(-- "${invocation[@]}")
  "${supervisor_args[@]}" >"$out" 2>"$err" &
  CHILD_PID=$!
  set +e; wait "$CHILD_PID"; PROVIDER_RC=$?; set -e
  CHILD_PID=""
}

cmd_run() {
  local task="" explicit_model="${PI_MODEL:-}" sandbox="workspace-write" base="HEAD" apply=0 start end duration
  ARCHETYPE="${LEGION_ARCHETYPE:-}"; PRESET_RUN_ID=""; THINKING="${LEGION_PI_THINKING:-${PI_THINKING:-}}"; PROVIDER_RC=0
  [[ "$ADAPTER_KIND" == hermes ]] && explicit_model="${HERMES_MODEL:-}"
  while [[ $# -gt 0 ]]; do case "$1" in
    --task) task="$2"; shift 2;;
    --task-file) [[ -r "$2" ]] || die "--task-file not readable: $2"; task="$(cat "$2")"; shift 2;; --model) explicit_model="$2"; shift 2;; --thinking) [[ "$ADAPTER_KIND" == pi ]] || die '--thinking is only supported by Pi'; THINKING="$2"; shift 2;;
    --archetype) ARCHETYPE="$2"; shift 2;; --repo) REPO="$2"; shift 2;; --base) base="$2"; shift 2;; --sandbox) sandbox="$2"; shift 2;;
    --run-id) PRESET_RUN_ID="$2"; shift 2;; --apply) apply=1; shift;; --keep) KEEP=1; shift;; --quiet) QUIET=1; shift;; *) die "run: unknown arg '$1'";; esac; done
  # The OS sandbox matches canonical paths. On macOS, /tmp is a symlink to
  # /private/tmp, so a logical path would deny legitimate worktree writes.
  REPO="$(cd "${REPO:-$PWD}" && pwd -P)" || die 'run: repo does not exist'
  resolve_state "$REPO"; BASE="$base"; SANDBOX="$sandbox"
  case "$SANDBOX" in read-only|workspace-write) ;; *) die "invalid --sandbox '$SANDBOX' (read-only|workspace-write)";; esac
  # Hermes currently exposes no documented read-only/no-tools one-shot flag.
  [[ "$ADAPTER_KIND" != hermes || "$SANDBOX" != read-only ]] || die 'read-only is unsupported by Hermes --oneshot; refusing to weaken isolation.'
  [[ -n "$task" ]] || task="$(cat)"; [[ -n "$task" ]] || die 'run: empty task'
  [[ "$SANDBOX" == read-only ]] || legion_scan_task_text "$task"
  legion_require_top_level_executor "$ADAPTER_KIND" || return $?
  [[ -z "$PRESET_RUN_ID" ]] || { declare -F legion_write_adapter_run_state >/dev/null 2>&1 || die 'run: --run-id requires lifecycle-state support'; legion_validate_run_id "$PRESET_RUN_ID" || die "run: invalid --run-id '$PRESET_RUN_ID'"; }
  MODEL="$explicit_model"; [[ -n "$MODEL" ]] || MODEL="$(legion_model_ref "${ADAPTER_KIND}_default")" || die "could not resolve ${ADAPTER_KIND}_default"
  if [[ "$ADAPTER_KIND" == pi && "$MODEL" =~ :(off|minimal|low|medium|high|xhigh|max)$ ]]; then
    [[ -n "$THINKING" ]] || THINKING="${BASH_REMATCH[1]}"; MODEL="${MODEL%:*}"
  fi
  [[ "$ADAPTER_KIND" != pi || -z "$THINKING" ]] || valid_thinking "$THINKING" || die "invalid --thinking '$THINKING' (off|minimal|low|medium|high|xhigh|max)"
  RUN_ID="${PRESET_RUN_ID:-$(_run_id)}"; WT="$REPO/.legion/worktrees/$RUN_ID"; WT_RECORD="$WT"; ART="$REPO/.legion/runs/$RUN_ID"; BRANCH="legion/$ADAPTER_KIND-$RUN_ID"
  [[ -z "$PRESET_RUN_ID" ]] || legion_arm_adopted_run_guard "$RUN_ID" "$REPO" "$ART" "$WT" "$BRANCH" "$MODEL" "$SANDBOX" "$BASE" "$ARCHETYPE" "$THINKING"
  provider_ready
  resolve_fs_sandbox
  git -C "$REPO" rev-parse --is-inside-work-tree >/dev/null 2>&1 || die "not a git repo: $REPO"
  prepare_runtime_roots
  with_git_worktree_lock "$REPO" git -C "$REPO" worktree add -q -b "$BRANCH" "$WT" "$BASE" \
    || { write_state failed; die 'worktree add failed'; }
  WT_CREATED=1 BRANCH_CREATED=1
  prepare_trusted_git_metadata
  write_worktree_ownership || { write_state failed; die 'unable to persist worktree ownership receipt'; }
  prepare_provider_files
  prepare_private_provider_runtime
  write_state running; legion_activate_executor_context "$RUN_ID" "$ADAPTER_KIND"
  start_handoff_broker
  local out="$PROVIDER_OUT" err="$PROVIDER_ERR" usage_art="$PROVIDER_USAGE"; local -a command
  if [[ "$ADAPTER_KIND" == pi ]]; then
    command=("$PROVIDER_BIN" -p --mode json --no-session --no-approve --no-extensions --no-skills --no-prompt-templates --model "$MODEL")
    [[ -z "$THINKING" ]] || command+=(--thinking "$THINKING")
    [[ "$SANDBOX" == read-only ]] && command+=(--tools "read,grep,find,ls")
    command+=("$task")
  else
    # Keep repository rules/AGENTS.md, but exclude the user's tools, MCPs,
    # hooks, plugins, and mutable profile from non-interactive auto-approval.
    command=("$PROVIDER_BIN" --oneshot "$task" --usage-file "$usage_art" --model "$MODEL" \
      --ignore-user-config --toolsets "terminal,file")
  fi
  note "-> ${command[*]}"
  start="$(date +%s000)"; run_provider "$out" "$err" "${command[@]}"; end="$(date +%s000)"; duration=$((end-start))
  stop_handoff_broker
  local usage='{}' result='' cost=0 status=ok diff="$ART/diff.patch" actual_model="$MODEL" terminal_ok=0 provider_files_ok=0
  if verify_provider_file "$out" "$PROVIDER_OUT_ID" \
      && verify_provider_file "$err" "$PROVIDER_ERR_ID" \
      && verify_provider_file "$usage_art" "$PROVIDER_USAGE_ID"; then
    provider_files_ok=1
  else
    status=error
    result="$ADAPTER_KIND modified or replaced a parent-owned provider artifact; refusing to consume it."
  fi
  if [[ "$provider_files_ok" == 1 && "$ADAPTER_KIND" == pi ]]; then
    usage="$(pi_usage "$out")"; result="$(pi_result "$out")"; pi_terminal_ok "$out" && terminal_ok=1 || true
    actual_model="$(pi_actual_model "$out")"; [[ -n "$actual_model" ]] || actual_model="$MODEL"
    cost="$(pi_cost "$out")"
  elif [[ "$provider_files_ok" == 1 ]]; then
    usage="$(hermes_usage "$usage_art")"; result="$(hermes_result "$out")"; hermes_terminal_ok "$out" "$usage_art" && terminal_ok=1 || true
    actual_model="$(hermes_actual_model "$usage_art")"; [[ -n "$actual_model" ]] || actual_model="$MODEL"
    cost="$(hermes_cost "$usage_art")"
  fi
  MODEL="$actual_model"
  [[ -n "$usage" ]] || usage='{}'
  if [[ "$BROKER_RC" -ne 0 ]]; then
    status=failed
    result="${result:+$result$'\n'}handoff broker failed closed with exit $BROKER_RC; inspect $ART/broker.err"
  fi
  if ! jq -en --argjson value "$cost" '$value | type == "number" and . >= 0' >/dev/null 2>&1; then cost=0; terminal_ok=0; fi
  if ! capture_trusted_diff "$diff"; then
    status=error
    result="${result:+$result$'\n'}$ADAPTER_KIND modified trusted worktree metadata or diff capture failed; refusing unsandboxed Git evaluation."
  fi
  [[ "$PROVIDER_RC" == 0 ]] || status=failed
  [[ "$status" != ok || "$terminal_ok" == 1 ]] || status=error
  # A successful exit alone is not a terminal receipt. Both providers must
  # produce a final answer (Pi's agent_end, Hermes's one-shot stdout) before
  # Legion can report an authoritative success.
  [[ "$status" != ok || -n "$result" ]] || status=error
  [[ "$SANDBOX" != read-only || ! -s "$diff" ]] || { status=error; result="${result:+$result$'\n'}Pi produced file changes during a read-only run; refusing to report ok."; }
  [[ "$status" != ok || -n "$result" || -s "$diff" ]] || { status=error; result="$ADAPTER_KIND completed without an authoritative terminal result or diff."; }
  printf '%s\n' "$result" > "$ART/last-message.txt"
  local cost_provenance='{"cost_status":"unknown","cost_source":"none"}'
  [[ "$ADAPTER_KIND" != hermes ]] || cost_provenance="$(hermes_cost_provenance "$usage_art")"
  local artifacts; artifacts="$(jq -cn --arg worktree "$WT_RECORD" --arg diff "$diff" --arg stdout "$out" --arg stderr "$err" --arg usage "$usage_art" --argjson cost_provenance "$cost_provenance" '{worktree:$worktree,diff:$diff,stdout:$stdout,stderr:$stderr,usage_file:$usage} + $cost_provenance')"
  emit_span "$status" "$duration" "$cost" "$usage" "$task" "$artifacts"
  if [[ "$apply" == 1 && "$status" == ok && -s "$diff" ]]; then
    if git -C "$REPO" apply --check "$diff"; then git -C "$REPO" apply "$diff"; else note "diff did not apply cleanly; left in $diff"; fi
  fi
  local report="$WT_RECORD"; [[ "$KEEP" == 1 ]] || { cleanup_worktree; report='(removed; rerun with --keep to retain the worktree)'; }
  write_state "$status"; [[ -z "$PRESET_RUN_ID" ]] || legion_disarm_adopted_run_guard
  jq -cn --arg run "$RUN_ID" --arg status "$status" --arg executor "$ADAPTER_KIND" --arg model "$actual_model" --arg result "$result" --arg worktree "$report" --arg diff "$diff" --arg last "$ART/last-message.txt" --argjson usage "$usage" --argjson cost "$cost" --argjson rc "$PROVIDER_RC" '{run_id:$run,status:$status,executor:$executor,model:$model,result:$result,worktree:$worktree,diff_path:$diff,last_message_path:$last,usage:$usage,cost_usd:$cost,provider_exit:$rc}'
  [[ "$status" == ok ]] || exit 1
}

usage() { printf '%s — isolated, metered %s diff adapter.\n\nUsage: %s run --task TASK [--model MODEL] [--repo DIR] [--sandbox read-only|workspace-write] [--base REF] [--run-id ID] [--apply] [--keep]\n' "$ADAPTER" "$ADAPTER_KIND" "$ADAPTER"; }
case "${1:-}" in run) shift; cmd_run "$@";; ''|help|-h|--help) usage;; *) die "unknown command '$1'";; esac
