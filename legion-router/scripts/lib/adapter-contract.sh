#!/usr/bin/env bash
# Shared no-spend admission plus truthful provider-attempt receipts.
#
# A preflight refusal is not an attempt: no legion.attempt.v1 or
# legion.failure.v1 is emitted until a provider process has actually launched.
# The preflight receipt is therefore the complete terminal evidence for an
# admission refusal.  After launch, every call gets exactly one attempt receipt
# and every failed call gets one failure receipt bound to that attempt.

# These globals are the shell-side return contract consumed by adapter callers.
# shellcheck disable=SC2034
LEGION_ADAPTER_PREFLIGHT_STATUS=""
# shellcheck disable=SC2034
LEGION_ADAPTER_PREFLIGHT_REASON=""
# shellcheck disable=SC2034
LEGION_ADAPTER_CONFIG_IDENTITY=""
# shellcheck disable=SC2034
LEGION_ADAPTER_PREFLIGHT_CACHE_KEY=""
# shellcheck disable=SC2034
LEGION_ADAPTER_PREFLIGHT_PATH=""
# shellcheck disable=SC2034
LEGION_ADAPTER_ATTEMPT_PATH=""
# shellcheck disable=SC2034
LEGION_ADAPTER_FAILURE_PATH=""
# shellcheck disable=SC2034
LEGION_ADAPTER_PREVIOUS_ATTEMPT_ID=""
# Effective child-only hard lease resolved from the executor registry.
LEGION_ADAPTER_MAX_RUNTIME_SECONDS=""
LEGION_ADAPTER_LEASE_REASON=""
LEGION_ADAPTER_SUPERVISOR=""
LEGION_ADAPTER_SIGNAL_ARMED=0
LEGION_ADAPTER_SIGNAL_ART=""
LEGION_ADAPTER_SIGNAL_EXECUTOR=""
LEGION_ADAPTER_SIGNAL_PROVIDER=""
LEGION_ADAPTER_SIGNAL_ORDINAL=""
LEGION_ADAPTER_SIGNAL_REQUESTED_MODEL=""
LEGION_ADAPTER_SIGNAL_EFFECTIVE_MODEL=""
LEGION_ADAPTER_SIGNAL_REQUESTED_EFFORT=""
LEGION_ADAPTER_SIGNAL_EFFECTIVE_EFFORT=""
LEGION_ADAPTER_SIGNAL_SANDBOX=""
LEGION_ADAPTER_SIGNAL_STARTED_AT=""
LEGION_ADAPTER_SIGNAL_START_MS=""
LEGION_ADAPTER_SIGNAL_OUTPUT_FILE=""
LEGION_ADAPTER_SIGNAL_TERMINALIZED=0
LEGION_ADAPTER_PROVIDER_SPAN_CLAIM_TOKEN=""

legion_adapter_contract_root() {
  local lib_dir
  lib_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  cd "$lib_dir/../../.." && pwd
}

legion_adapter_resolve_lease() {
  local executor="$1" requested="${2:-}" root route info declared
  root="$(legion_adapter_contract_root)"
  route="$root/legion-router/scripts/legion-route.py"
  LEGION_ADAPTER_LEASE_REASON=""
  if [[ ! -f "$route" ]] || ! info="$(python3 "$route" --executor-info "$executor" 2>/dev/null)"; then
    LEGION_ADAPTER_LEASE_REASON="executor '$executor' has no readable lease declaration"
    return 1
  fi
  declared="$(jq -r '.max_runtime_seconds // empty' <<<"$info" 2>/dev/null || true)"
  if [[ ! "$declared" =~ ^[1-9][0-9]*$ ]]; then
    LEGION_ADAPTER_LEASE_REASON="executor '$executor' has no positive max_runtime_seconds"
    return 1
  fi
  if [[ -n "$requested" ]]; then
    if [[ ! "$requested" =~ ^[1-9][0-9]*$ ]]; then
      LEGION_ADAPTER_LEASE_REASON="--max-runtime-seconds must be a positive integer"
      return 1
    fi
    if [[ "${#requested}" -gt "${#declared}" ||
          ( "${#requested}" -eq "${#declared}" && "$requested" > "$declared" ) ]]; then
      LEGION_ADAPTER_LEASE_REASON="--max-runtime-seconds may lower but not raise executor '$executor' default ($declared)"
      return 1
    fi
    LEGION_ADAPTER_MAX_RUNTIME_SECONDS="$requested"
  else
    LEGION_ADAPTER_MAX_RUNTIME_SECONDS="$declared"
  fi
  LEGION_ADAPTER_SUPERVISOR="$root/legion-router/scripts/legion-process-supervisor.py"
  if [[ ! -x "$LEGION_ADAPTER_SUPERVISOR" ]]; then
    LEGION_ADAPTER_LEASE_REASON="descendant-aware process supervisor is unavailable"
    return 1
  fi
}

legion_adapter_supervisor_timed_out() {
  local status_file="$1"
  [[ -f "$status_file" ]] \
    && jq -e '.schema == "legion.child-execution-lease.v1" and .status == "timed_out"' \
      "$status_file" >/dev/null 2>&1
}

legion_adapter_supervisor_cleanup_failed() {
  local status_file="$1"
  [[ -f "$status_file" ]] \
    && jq -e '.schema == "legion.child-execution-lease.v1" and .status == "cleanup_failed"' \
      "$status_file" >/dev/null 2>&1
}

legion_adapter_supervisor_cleanup_failed_before_launch() {
  local status_file="$1"
  [[ -f "$status_file" ]] \
    && jq -e '
      .schema == "legion.child-execution-lease.v1"
      and .status == "cleanup_failed"
      and .child_started == false
      and (.reason | type == "string" and length > 0)
      and (.max_runtime_seconds | type == "number" and . >= 1 and . == floor)
      and (has("child_exit_code") | not)
      and ((keys_unsorted - ["schema", "status", "reason", "max_runtime_seconds", "child_started"]) | length == 0)
    ' "$status_file" >/dev/null 2>&1
}

# A launch_failed sidecar is authoritative no-spend evidence: the supervisor
# writes it only when Popen raised before returning a child handle. Validate the
# complete typed shape so a malformed or contradictory receipt cannot suppress
# provider accounting.
legion_adapter_supervisor_launch_failed() {
  local status_file="$1"
  legion_adapter_supervisor_cleanup_failed_before_launch "$status_file" && return 0
  [[ -f "$status_file" ]] \
    && jq -e '
      .schema == "legion.child-execution-lease.v1"
      and .status == "launch_failed"
      and (.reason | type == "string" and length > 0)
      and (.max_runtime_seconds | type == "number" and . >= 1 and . == floor)
      and (has("child_exit_code") | not)
      and ((keys_unsorted - ["schema", "status", "reason", "max_runtime_seconds"]) | length == 0)
    ' "$status_file" >/dev/null 2>&1
}

legion_adapter_supervisor_reason() {
  local status_file="$1" fallback="${2:-child supervisor reported an internal containment failure}" reason=""
  reason="$(jq -r '.reason // empty' "$status_file" 2>/dev/null || true)"
  printf '%s' "${reason:-$fallback}"
}

legion_adapter_lease_reason() {
  local status_file="$1" reason=""
  reason="$(jq -r '.reason // empty' "$status_file" 2>/dev/null || true)"
  if [[ -n "$reason" ]]; then
    printf '%s' "$reason"
  else
    printf 'child execution lease expired after %s seconds' "$LEGION_ADAPTER_MAX_RUNTIME_SECONDS"
  fi
}

legion_adapter_preflight() {
  local executor="$1" art="$2" sandbox="$3" transport="$4"
  local model="${5:-}" effort="${6:-}" consent="${7:-0}" binary="${8:-}"
  local root preflight tmp rc=0
  root="$(legion_adapter_contract_root)"
  preflight="$root/legion-router/bin/legion-preflight"
  LEGION_ADAPTER_PREFLIGHT_PATH="$art/$executor-preflight.json"
  mkdir -p "$art"
  tmp="$LEGION_ADAPTER_PREFLIGHT_PATH.tmp.$$"
  local -a args=(--json --executor "$executor" --sandbox "$sandbox"
    --read-mode provider-tools --task-transport "$transport")
  [[ -z "$model" ]] || args+=(--model "$model")
  [[ -z "$effort" ]] || args+=(--effort "$effort")
  [[ "$consent" != 1 ]] || args+=(--explicit-consent)
  [[ -z "$binary" ]] || args+=(--binary "$binary")
  if [[ ! -x "$preflight" ]]; then
    jq -cn --arg executor "$executor" --arg checked "$(date -u +%Y-%m-%dT%H:%M:%SZ)" '
      {schema:"legion.preflight.v1",checked_at:$checked,executor:$executor,
       status:"unavailable",reason:"shared Legion preflight is unavailable",
       identity:null,cache:{hit:false,key:null},compatibility:{}}' > "$tmp"
    rc=1
  else
    set +e
    "$preflight" "${args[@]}" > "$tmp"
    rc=$?
    set -e
    if ! jq -e '.schema == "legion.preflight.v1"' "$tmp" >/dev/null 2>&1; then
      jq -cn --arg executor "$executor" --arg checked "$(date -u +%Y-%m-%dT%H:%M:%SZ)" '
        {schema:"legion.preflight.v1",checked_at:$checked,executor:$executor,
         status:"unavailable",reason:"shared Legion preflight returned an invalid receipt",
         identity:null,cache:{hit:false,key:null},compatibility:{}}' > "$tmp"
      rc=1
    fi
  fi
  chmod 600 "$tmp" 2>/dev/null || true
  mv -f "$tmp" "$LEGION_ADAPTER_PREFLIGHT_PATH"
  cp "$LEGION_ADAPTER_PREFLIGHT_PATH" "$art/preflight.json"
  LEGION_ADAPTER_PREFLIGHT_STATUS="$(jq -r '.status' "$LEGION_ADAPTER_PREFLIGHT_PATH")"
  # shellcheck disable=SC2034
  LEGION_ADAPTER_PREFLIGHT_REASON="$(jq -r '.reason' "$LEGION_ADAPTER_PREFLIGHT_PATH")"
  LEGION_ADAPTER_CONFIG_IDENTITY="$(jq -r '.identity.config_sha256 // empty' "$LEGION_ADAPTER_PREFLIGHT_PATH")"
  LEGION_ADAPTER_PREFLIGHT_CACHE_KEY="$(jq -r '.cache.key // empty' "$LEGION_ADAPTER_PREFLIGHT_PATH")"
  [[ "$rc" -eq 0 && "$LEGION_ADAPTER_PREFLIGHT_STATUS" == supported ]]
}

legion_adapter_write_attempt() {
  local art="$1" executor="$2" provider="$3" ordinal="$4"
  local requested_model="$5" effective_model="$6" requested_effort="$7" effective_effort="$8"
  local sandbox="$9" terminal_status="${10}" started_at="${11}" ended_at="${12}" duration_ms="${13}"
  local usage="${14}" usage_status="${15}" usage_source="${16}"
  local cost="${17}" cost_status="${18}" cost_source="${19}"
  local failure_class="${20}" retryable="${21}" output_started="${22}"
  local provider_code="${23:-}" message="${24:-}"
  local attempt_id="${RUN_ID}-${executor}-attempt-${ordinal}"
  local failure_id="${RUN_ID}-${executor}-failure-${ordinal}"
  local attempt_path="$art/attempt-$ordinal.json" failure_path="$art/failure-$ordinal.json"
  local tmp="$attempt_path.tmp.$$" failure_json=null usage_json=null cost_json=null

  case "$usage_status" in
    known)
      if [[ -n "$usage_source" ]] && usage_json="$(jq -cSse '
        if length == 1
           and (.[0] | type == "object"
                and all(keys[]; length > 0)
                and all(.[]; type == "number"
                            and (isnan | not)
                            and (isinfinite | not)
                            and . >= 0
                            and . == floor
                            and (tostring | test("^(0|[1-9][0-9]*)$"))))
        then .[0]
        else error("invalid provider usage")
        end
      ' <<<"$usage" 2>/dev/null)"; then
        :
      else
        printf '%s\n' \
          'legion adapter receipt: invalid known usage; recording usage as unknown' >&2
        usage_status=unknown
        usage_source=""
        usage_json=null
      fi
      ;;
    unknown|not_applicable)
      usage_source=""
      usage_json=null
      ;;
    *)
      printf 'legion adapter receipt: invalid usage status %q; recording usage as unknown\n' \
        "$usage_status" >&2
      usage_status=unknown
      usage_source=""
      usage_json=null
      ;;
  esac

  case "$cost_status" in
    known)
      if [[ -n "$cost_source" ]] && cost_json="$(jq -cse '
        if length == 1
           and (.[0] | type == "number"
                and (isnan | not)
                and (isinfinite | not)
                and . >= 0)
        then .[0]
        else error("invalid provider cost")
        end
      ' <<<"$cost" 2>/dev/null)"; then
        :
      else
        printf '%s\n' \
          'legion adapter receipt: invalid known cost; recording cost as unknown' >&2
        cost_status=unknown
        cost_source=""
        cost_json=null
      fi
      ;;
    unknown|not_applicable)
      cost_source=""
      cost_json=null
      ;;
    *)
      printf 'legion adapter receipt: invalid cost status %q; recording cost as unknown\n' \
        "$cost_status" >&2
      cost_status=unknown
      cost_source=""
      cost_json=null
      ;;
  esac

  if [[ -n "$failure_class" ]]; then
    failure_json="$(jq -cn \
      --arg id "$failure_id" --arg run "$RUN_ID" --arg attempt "$attempt_id" \
      --arg ts "$ended_at" --arg class "$failure_class" --arg code "$provider_code" \
      --arg message "$message" --argjson retryable "$retryable" \
      --argjson output_started "$output_started" '
      {schema:"legion.failure.v1",failure_id:$id,run_id:$run,attempt_id:$attempt,ts:$ts,
       class:$class,provider_code:(if $code=="" then null else $code end),retryable:$retryable,
       output_started:$output_started,message:(if $message=="" then null else $message end)}')"
    printf '%s\n' "$failure_json" > "$failure_path.tmp.$$"
    chmod 600 "$failure_path.tmp.$$" 2>/dev/null || true
    mv -f "$failure_path.tmp.$$" "$failure_path"
    cp "$failure_path" "$art/failure.json"
    LEGION_ADAPTER_FAILURE_PATH="$failure_path"
  else
    # failure.json is a mutable alias for the latest provider attempt. Preserve
    # numbered failures as history, but never let a successful retry inherit a
    # stale failure alias or shell-side pointer from the previous attempt.
    rm -f "$art/failure.json"
    # shellcheck disable=SC2034
    LEGION_ADAPTER_FAILURE_PATH=""
  fi

  jq -cn \
    --arg attempt_id "$attempt_id" --arg run "$RUN_ID" --argjson ordinal "$ordinal" \
    --arg executor "$executor" --arg provider "$provider" \
    --arg config "${LEGION_ADAPTER_CONFIG_IDENTITY:-unknown-config}" \
    --arg requested_model "$requested_model" --arg effective_model "$effective_model" \
    --arg requested_effort "$requested_effort" --arg effective_effort "$effective_effort" \
    --arg cache_key "$LEGION_ADAPTER_PREFLIGHT_CACHE_KEY" \
    --arg previous "$LEGION_ADAPTER_PREVIOUS_ATTEMPT_ID" \
    --argjson usage "$usage_json" --arg usage_status "$usage_status" --arg usage_source "$usage_source" \
    --argjson cost "$cost_json" --arg cost_status "$cost_status" --arg cost_source "$cost_source" \
    --argjson failure "$failure_json" --argjson output_started "$output_started" \
    --arg started "$started_at" --arg ended "$ended_at" --argjson duration "$duration_ms" \
    --arg sandbox "$sandbox" --arg terminal "$terminal_status" '
    {schema:"legion.attempt.v1",attempt_id:$attempt_id,attempt_kind:"provider",run_id:$run,
     parent_attempt_id:null,ordinal:$ordinal,executor:$executor,provider:$provider,
     config_identity:$config,
     requested_model:(if $requested_model=="" then null else $requested_model end),
     effective_model:(if $effective_model=="" then null else $effective_model end),
     requested_effort:(if $requested_effort=="" then null else $requested_effort end),
     effective_effort:(if $effective_effort=="" then null else $effective_effort end),
     cache_lineage:{preflight_cache_key:(if $cache_key=="" then null else $cache_key end),
                    previous_attempt_id:(if $previous=="" then null else $previous end)},
     usage:$usage,usage_status:$usage_status,
     usage_source:(if $usage_source=="" then null else $usage_source end),
     cost_usd:$cost,cost_status:$cost_status,
     cost_source:(if $cost_source=="" then null else $cost_source end),
     failure:$failure,output_started:$output_started,started_at:$started,ended_at:$ended,
     duration_ms:$duration,sandbox:$sandbox,terminal_status:$terminal,
     child_attempt_ids:[],reconciliation:null}' > "$tmp"
  chmod 600 "$tmp" 2>/dev/null || true
  mv -f "$tmp" "$attempt_path"
  cp "$attempt_path" "$art/attempt.json"
  # shellcheck disable=SC2034
  LEGION_ADAPTER_ATTEMPT_PATH="$attempt_path"
  LEGION_ADAPTER_PREVIOUS_ATTEMPT_ID="$attempt_id"
}

legion_adapter_arm_signal_receipt() {
  LEGION_ADAPTER_SIGNAL_ART="$1"
  LEGION_ADAPTER_SIGNAL_EXECUTOR="$2"
  LEGION_ADAPTER_SIGNAL_PROVIDER="$3"
  LEGION_ADAPTER_SIGNAL_ORDINAL="$4"
  LEGION_ADAPTER_SIGNAL_REQUESTED_MODEL="$5"
  LEGION_ADAPTER_SIGNAL_EFFECTIVE_MODEL="$6"
  LEGION_ADAPTER_SIGNAL_REQUESTED_EFFORT="$7"
  LEGION_ADAPTER_SIGNAL_EFFECTIVE_EFFORT="$8"
  LEGION_ADAPTER_SIGNAL_SANDBOX="$9"
  LEGION_ADAPTER_SIGNAL_STARTED_AT="${10}"
  LEGION_ADAPTER_SIGNAL_START_MS="${11}"
  LEGION_ADAPTER_SIGNAL_OUTPUT_FILE="${12:-}"
  LEGION_ADAPTER_SIGNAL_TERMINALIZED=0
  LEGION_ADAPTER_SIGNAL_ARMED=1
}

legion_adapter_disarm_signal_receipt() {
  LEGION_ADAPTER_SIGNAL_ARMED=0
}

legion_adapter_provider_span_is_durable() {
  local attempt_path="$1" span_file
  [[ -n "$attempt_path" && -d "${LEGION_TELEMETRY_DIR:-}" ]] || return 1
  for span_file in "$LEGION_TELEMETRY_DIR"/*.jsonl; do
    [[ -f "$span_file" ]] || continue
    jq -R -e --arg attempt "$attempt_path" '
      try (fromjson | select(.schema == "legion.span.v1"
        and .artifacts.provider_attempt == true
        and .artifacts.rollup_only != true
        and .artifacts.attempt_receipt == $attempt)) catch empty
    ' "$span_file" >/dev/null 2>&1 && return 0
  done
  return 1
}

legion_adapter_claim_provider_span() {
  local attempt_path="$1" claim_path owner_path lock_path outcome
  [[ -n "$attempt_path" ]] || return 1
  claim_path="$attempt_path.provider-span-emitted"
  owner_path="$claim_path/owner.json"
  lock_path="$claim_path/owner.lock"
  [[ ! -L "$claim_path" ]] || return 1
  mkdir -p "$claim_path" 2>/dev/null || return 1
  outcome="$(python3 - "$lock_path" "$owner_path" "$$" <<'PY'
import fcntl
import json
import os
import re
import secrets
import stat
import subprocess
import sys
import tempfile
from datetime import datetime

lock_path, owner_path, publisher_pid_text = sys.argv[1:]
publisher_pid = int(publisher_pid_text)

def process_snapshot(pid):
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        return False, None, None
    except PermissionError:
        pass
    boot = None
    if sys.platform.startswith("linux"):
        try:
            with open("/proc/sys/kernel/random/boot_id", encoding="ascii") as source:
                boot = source.read(80).strip()
        except OSError:
            pass
    elif sys.platform == "darwin":
        try:
            result = subprocess.run(
                ["/usr/sbin/sysctl", "-n", "kern.boottime"],
                check=False, capture_output=True, text=True, timeout=1,
                env={"LC_ALL": "C", "PATH": "/usr/bin:/bin:/usr/sbin"},
            )
            match = re.search(r"sec\s*=\s*(\d+)", result.stdout[:256])
            if result.returncode == 0 and match:
                boot = match.group(1)
        except (OSError, subprocess.SubprocessError):
            pass
    try:
        result = subprocess.run(
            ["/bin/ps", "-o", "lstart=", "-p", str(pid)],
            check=False, capture_output=True, text=True, timeout=1,
            env={"LC_ALL": "C", "PATH": "/usr/bin:/bin"},
        )
        started = result.stdout.strip()
        if result.returncode != 0 or not started or len(started) > 128 or not boot:
            return True, None, None
        started_epoch = datetime.strptime(started, "%a %b %d %H:%M:%S %Y").timestamp()
        return True, f"{sys.platform}:{boot}:{started}", started_epoch
    except (OSError, ValueError, subprocess.SubprocessError):
        return True, None, None

def current_publisher_incarnation(pid):
    # A process supervisor contributes a fresh, unguessable token to exactly
    # one supervised execution tree.  Prefer that token for the publisher
    # itself: macOS Seatbelt intentionally denies the process inspection that
    # ps(1) needs inside brokered harnesses.  Other-owner checks still use the
    # host start time when it is observable.
    supervisor_token = os.environ.get("LEGION_SUPERVISOR_TOKEN", "")
    if re.fullmatch(r"[0-9a-f]{48}", supervisor_token):
        return f"supervisor:{supervisor_token}:pid:{pid}"
    alive, incarnation, _ = process_snapshot(pid)
    return incarnation if alive else None

flags = os.O_RDWR | os.O_CREAT
if hasattr(os, "O_NOFOLLOW"):
    flags |= os.O_NOFOLLOW
descriptor = os.open(lock_path, flags, 0o600)
with os.fdopen(descriptor, "r+", encoding="utf-8") as lock:
    lock_stat = os.fstat(lock.fileno())
    if not stat.S_ISREG(lock_stat.st_mode) or lock_stat.st_nlink != 1:
        raise SystemExit(1)
    os.fchmod(lock.fileno(), 0o600)
    try:
        fcntl.flock(lock.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
    except BlockingIOError:
        print("busy")
        raise SystemExit(0)
    path_stat = os.stat(lock_path, follow_symlinks=False)
    if (path_stat.st_dev, path_stat.st_ino) != (lock_stat.st_dev, lock_stat.st_ino):
        raise SystemExit(1)
    publisher_incarnation = current_publisher_incarnation(publisher_pid)
    if not publisher_incarnation:
        raise SystemExit(1)
    owner = None
    legacy_owner = None
    owner_mtime = None
    try:
        owner_mtime = os.stat(owner_path, follow_symlinks=False).st_mtime
        with open(owner_path, encoding="utf-8") as source:
            candidate = json.load(source)
        if (
            candidate.get("schema") == "legion.provider-span-claim.v1"
            and isinstance(candidate.get("publisher_pid"), int)
            and candidate["publisher_pid"] > 0
            and isinstance(candidate.get("publisher_incarnation"), str)
            and candidate["publisher_incarnation"]
            and isinstance(candidate.get("token"), str)
            and candidate["token"]
            and set(candidate) == {"schema", "publisher_pid", "publisher_incarnation", "token"}
        ):
            owner = candidate
        elif (
            candidate.get("schema") == "legion.provider-span-claim.v1"
            and isinstance(candidate.get("publisher_pid"), int)
            and candidate["publisher_pid"] > 0
            and isinstance(candidate.get("token"), str)
            and candidate["token"]
            and set(candidate) == {"schema", "publisher_pid", "token"}
        ):
            legacy_owner = candidate
    except (OSError, ValueError, TypeError):
        pass
    if owner:
        if owner["publisher_pid"] == publisher_pid:
            owner_alive, owner_incarnation = True, publisher_incarnation
        else:
            owner_alive, owner_incarnation, _ = process_snapshot(owner["publisher_pid"])
        if owner_alive and (owner_incarnation is None or owner_incarnation == owner["publisher_incarnation"]):
            print("busy")
            raise SystemExit(0)
    elif legacy_owner:
        owner_alive, _, owner_started = process_snapshot(legacy_owner["publisher_pid"])
        if owner_alive and (owner_started is None or owner_mtime is None or owner_started <= owner_mtime + 1.0):
            print("busy")
            raise SystemExit(0)
    token = secrets.token_hex(24)
    directory = os.path.dirname(owner_path)
    descriptor, temporary = tempfile.mkstemp(prefix=".owner.", suffix=".tmp", dir=directory)
    try:
        with os.fdopen(descriptor, "w", encoding="utf-8") as destination:
            json.dump(
                {
                    "schema": "legion.provider-span-claim.v1",
                    "publisher_pid": publisher_pid,
                    "publisher_incarnation": publisher_incarnation,
                    "token": token,
                },
                destination,
                separators=(",", ":"),
            )
            destination.write("\n")
            destination.flush()
            os.fsync(destination.fileno())
        os.chmod(temporary, 0o600)
        os.replace(temporary, owner_path)
    finally:
        try:
            os.unlink(temporary)
        except FileNotFoundError:
            pass
    print(f"acquired:{token}")
PY
)" || return 1
  case "$outcome" in
    acquired:*) LEGION_ADAPTER_PROVIDER_SPAN_CLAIM_TOKEN="${outcome#acquired:}"; return 0 ;;
    *) return 1 ;;
  esac
}

legion_adapter_release_provider_span_claim() {
  local attempt_path="$1" token="${LEGION_ADAPTER_PROVIDER_SPAN_CLAIM_TOKEN:-}"
  local claim_path="$attempt_path.provider-span-emitted"
  [[ -n "$attempt_path" && -n "$token" && -d "$claim_path" && ! -L "$claim_path" ]] || return 0
  python3 - "$claim_path/owner.lock" "$claim_path/owner.json" "$token" "$$" <<'PY'
import fcntl
import json
import os
import re
import stat
import subprocess
import sys
from datetime import datetime

lock_path, owner_path, token, publisher_pid_text = sys.argv[1:]
publisher_pid = int(publisher_pid_text)

def process_incarnation(pid):
    supervisor_token = os.environ.get("LEGION_SUPERVISOR_TOKEN", "")
    if re.fullmatch(r"[0-9a-f]{48}", supervisor_token):
        return f"supervisor:{supervisor_token}:pid:{pid}"
    boot = None
    if sys.platform.startswith("linux"):
        try:
            with open("/proc/sys/kernel/random/boot_id", encoding="ascii") as source:
                boot = source.read(80).strip()
        except OSError:
            pass
    elif sys.platform == "darwin":
        try:
            result = subprocess.run(
                ["/usr/sbin/sysctl", "-n", "kern.boottime"],
                check=False, capture_output=True, text=True, timeout=1,
                env={"LC_ALL": "C", "PATH": "/usr/bin:/bin:/usr/sbin"},
            )
            match = re.search(r"sec\s*=\s*(\d+)", result.stdout[:256])
            if result.returncode == 0 and match:
                boot = match.group(1)
        except (OSError, subprocess.SubprocessError):
            pass
    try:
        result = subprocess.run(
            ["/bin/ps", "-o", "lstart=", "-p", str(pid)],
            check=False, capture_output=True, text=True, timeout=1,
            env={"LC_ALL": "C", "PATH": "/usr/bin:/bin"},
        )
        started = result.stdout.strip()
        if result.returncode != 0 or not started or len(started) > 128 or not boot:
            return None
        return f"{sys.platform}:{boot}:{started}"
    except (OSError, subprocess.SubprocessError):
        return None

publisher_incarnation = process_incarnation(publisher_pid)
if not publisher_incarnation:
    raise SystemExit(1)
flags = os.O_RDWR | os.O_CREAT
if hasattr(os, "O_NOFOLLOW"):
    flags |= os.O_NOFOLLOW
descriptor = os.open(lock_path, flags, 0o600)
with os.fdopen(descriptor, "r+", encoding="utf-8") as lock:
    lock_stat = os.fstat(lock.fileno())
    if not stat.S_ISREG(lock_stat.st_mode) or lock_stat.st_nlink != 1:
        raise SystemExit(1)
    fcntl.flock(lock.fileno(), fcntl.LOCK_EX)
    path_stat = os.stat(lock_path, follow_symlinks=False)
    if (path_stat.st_dev, path_stat.st_ino) != (lock_stat.st_dev, lock_stat.st_ino):
        raise SystemExit(1)
    try:
        with open(owner_path, encoding="utf-8") as source:
            owner = json.load(source)
    except (OSError, ValueError, TypeError):
        owner = None
    if (
        isinstance(owner, dict)
        and owner.get("schema") == "legion.provider-span-claim.v1"
        and owner.get("publisher_pid") == publisher_pid
        and owner.get("publisher_incarnation") == publisher_incarnation
        and owner.get("token") == token
    ):
        try:
            os.unlink(owner_path)
        except FileNotFoundError:
            pass
PY
  LEGION_ADAPTER_PROVIDER_SPAN_CLAIM_TOKEN=""
}

legion_adapter_acquire_provider_span_claim() {
  local attempt_path="$1" wait_ms="${LEGION_ADAPTER_PROVIDER_SPAN_CLAIM_WAIT_MILLISECONDS:-5000}"
  local elapsed=0 interval_ms=50
  [[ "$wait_ms" =~ ^[0-9]+$ ]] || wait_ms=5000
  while true; do
    legion_adapter_provider_span_is_durable "$attempt_path" && return 1
    legion_adapter_claim_provider_span "$attempt_path" && return 0
    legion_adapter_provider_span_is_durable "$attempt_path" && return 1
    (( elapsed >= wait_ms )) && return 1
    sleep 0.05
    elapsed=$((elapsed + interval_ms))
  done
}

# Normal publication and signal recovery use the same attempt-bound claim.
# If a trap interrupts after the claim but before/during emit_span, the signal
# path checks the durable JSONL record and takes over publication only when the
# normal append did not complete.
legion_adapter_emit_normal_provider_span() {
  local attempt_path="$1"
  shift
  if ! legion_adapter_acquire_provider_span_claim "$attempt_path"; then
    legion_adapter_provider_span_is_durable "$attempt_path" && return 0
    return 1
  fi
  # A prior owner may have died immediately after its atomic append while this
  # contender observed a transient partial JSON line. Reconcile once more after
  # serialized takeover before starting another publication.
  legion_adapter_provider_span_is_durable "$attempt_path" && return 0
  # Some adapter-local emitters deliberately swallow their underlying append
  # error. The durable attempt-bound record, rather than the emitter's return
  # code, is therefore the publication acknowledgement.
  emit_span "$@" || true
  legion_adapter_provider_span_is_durable "$attempt_path" && return 0
  legion_adapter_release_provider_span_claim "$attempt_path"
  return 1
}

legion_adapter_write_signal_receipt() {
  local signum="$1" child_rc="${2:-}" lease_path="${3:-}"
  local ended_at end_ms duration output_started=false message
  local terminal_status=cancelled failure_class=cancelled retryable=false
  local provider_code="$((128+signum))" lease_status=""
  [[ "$LEGION_ADAPTER_SIGNAL_ARMED" == 1 ]] || return 0
  LEGION_ADAPTER_SIGNAL_ARMED=0
  [[ -n "$LEGION_ADAPTER_SIGNAL_ART" && -n "${RUN_ID:-}" ]] || return 0
  LEGION_ADAPTER_SIGNAL_TERMINALIZED=1
  # A signal delivered after the normal receipt rename must not fabricate a
  # second terminal outcome for the same launched provider call.
  [[ ! -f "$LEGION_ADAPTER_SIGNAL_ART/attempt-$LEGION_ADAPTER_SIGNAL_ORDINAL.json" ]] || return 0
  lease_status="$(jq -r '
    if .schema == "legion.child-execution-lease.v1" then (.status // "") else "" end
  ' "$lease_path" 2>/dev/null || true)"
  local lease_child_rc
  lease_child_rc="$(jq -r '
    if .schema == "legion.child-execution-lease.v1"
       and (.child_exit_code | type) == "number"
    then (.child_exit_code | tostring) else "" end
  ' "$lease_path" 2>/dev/null || true)"
  [[ -z "$lease_child_rc" ]] || child_rc="$lease_child_rc"
  case "$lease_status" in
    cleanup_failed)
      if legion_adapter_supervisor_cleanup_failed_before_launch "$lease_path"; then
        LEGION_ADAPTER_SIGNAL_TERMINALIZED=0
        return 0
      fi
      message="provider attempt cancelled by signal $signum; containment cleanup failed"
      ;;
    launch_failed)
      # No provider existed to cancel and therefore no provider attempt/span is
      # permitted. Only the complete supervisor-authenticated shape can make
      # that claim; malformed lookalikes fail closed as launched attempts.
      if legion_adapter_supervisor_launch_failed "$lease_path"; then
        LEGION_ADAPTER_SIGNAL_TERMINALIZED=0
        return 0
      fi
      message="provider attempt cancelled by signal $signum; launch-failure sidecar was invalid"
      ;;
    completed)
      # Bash may dispatch a pending signal after wait(1) returned but before the
      # adapter committed its attempt. The retained wait result and supervisor
      # sidecar are authoritative: that provider call was not cancelled.
      if [[ "$child_rc" =~ ^[0-9]+$ && "$child_rc" -eq 0 ]]; then
        terminal_status=succeeded
        failure_class=""
        provider_code=""
        message="provider completed before signal $signum was dispatched"
      else
        terminal_status=failed
        failure_class=provider
        provider_code="${child_rc:-unknown}"
        message="provider exited before signal $signum was dispatched"
      fi
      ;;
    timed_out)
      terminal_status=timed_out
      failure_class=timed_out
      provider_code=124
      message="$(legion_adapter_lease_reason "$lease_path")"
      ;;
    *)
      message="provider attempt cancelled by signal $signum"
      ;;
  esac
  legion_adapter_output_started_file "$LEGION_ADAPTER_SIGNAL_OUTPUT_FILE" && output_started=true
  ended_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  end_ms="$(date +%s000)"
  duration=$((end_ms-LEGION_ADAPTER_SIGNAL_START_MS))
  (( duration >= 0 )) || duration=0
  legion_adapter_write_attempt \
    "$LEGION_ADAPTER_SIGNAL_ART" "$LEGION_ADAPTER_SIGNAL_EXECUTOR" \
    "$LEGION_ADAPTER_SIGNAL_PROVIDER" "$LEGION_ADAPTER_SIGNAL_ORDINAL" \
    "$LEGION_ADAPTER_SIGNAL_REQUESTED_MODEL" "$LEGION_ADAPTER_SIGNAL_EFFECTIVE_MODEL" \
    "$LEGION_ADAPTER_SIGNAL_REQUESTED_EFFORT" "$LEGION_ADAPTER_SIGNAL_EFFECTIVE_EFFORT" \
    "$LEGION_ADAPTER_SIGNAL_SANDBOX" "$terminal_status" "$LEGION_ADAPTER_SIGNAL_STARTED_AT" \
    "$ended_at" "$duration" '{}' unknown '' 0 unknown '' "$failure_class" "$retryable" \
    "$output_started" "$provider_code" "$message"
}

# Publish the provider span for a signal-terminalized attempt from the durable
# receipt, never from mutable shell variables. The claim directory makes a
# pending outer signal and an adapter-local trap safe to retry without double
# counting the same paid call.
legion_adapter_emit_signal_span() {
  local task_text="${1:-}" lease_path="${2:-}" attempt_path root trace_bin
  local executor model terminal span_status duration usage cost usage_status cost_status artifacts
  [[ "$LEGION_ADAPTER_SIGNAL_TERMINALIZED" == 1 ]] || return 0
  attempt_path="$LEGION_ADAPTER_SIGNAL_ART/attempt-$LEGION_ADAPTER_SIGNAL_ORDINAL.json"
  [[ -f "$attempt_path" ]] || return 0
  if ! legion_adapter_acquire_provider_span_claim "$attempt_path"; then
    legion_adapter_provider_span_is_durable "$attempt_path" && return 0
    return 1
  fi
  if ! jq -e '.schema == "legion.attempt.v1" and .attempt_kind == "provider"' \
      "$attempt_path" >/dev/null 2>&1; then
    legion_adapter_release_provider_span_claim "$attempt_path"
    return 1
  fi
  if legion_adapter_provider_span_is_durable "$attempt_path"; then
    return 0
  fi
  executor="$(jq -r '.executor' "$attempt_path")"
  model="$(jq -r '.effective_model // .requested_model // "unknown"' "$attempt_path")"
  terminal="$(jq -r '.terminal_status' "$attempt_path")"
  duration="$(jq -r '.duration_ms' "$attempt_path")"
  usage="$(jq -c '.usage' "$attempt_path")"
  cost="$(jq -c '.cost_usd' "$attempt_path")"
  usage_status="$(jq -r '.usage_status' "$attempt_path")"
  cost_status="$(jq -r '.cost_status' "$attempt_path")"
  case "$terminal" in
    succeeded) span_status=ok ;;
    timed_out) span_status=timed_out ;;
    *) span_status=failed ;;
  esac
  artifacts="$(jq -cn --arg attempt "$attempt_path" --arg lease "$lease_path" \
    '{provider_attempt:true,signal_terminalized:true,attempt_receipt:$attempt,
      lease_receipt:(if $lease=="" then null else $lease end)}')"
  root="$(legion_adapter_contract_root)"
  trace_bin="$root/legion-observability/bin/legion-trace"
  if [[ ! -x "$trace_bin" ]] || ! "$trace_bin" emit \
      --executor "$executor" --model "$model" --status "$span_status" \
      --run-id "$RUN_ID" --trace-id "${LEGION_TRACE_ID:-$RUN_ID}" \
      --parent-id "${LEGION_PARENT_ID:-}" --archetype "${archetype:-${ARCHETYPE:-}}" \
      --duration-ms "$duration" --cost "$cost" --cost-status "$cost_status" \
      --task "$task_text" --tokens "$usage" --usage-status "$usage_status" \
      --artifacts "$artifacts" >/dev/null 2>&1; then
    legion_adapter_release_provider_span_claim "$attempt_path"
    return 1
  fi
  legion_adapter_provider_span_is_durable "$attempt_path" && return 0
  legion_adapter_release_provider_span_claim "$attempt_path"
  return 1
}

# Reclassify an already-recorded provider call when an adapter-level invariant
# (for example a read-only write backstop) fails after output parsing. This
# preserves the original timing, model, cost, and lineage rather than fabricating
# a second provider attempt.
legion_adapter_fail_recorded_attempt() {
  local art="$1" executor="$2" ordinal="$3" failure_class="$4"
  local provider_code="${5:-}" message="${6:-}"
  local attempt_path="$art/attempt-$ordinal.json" failure_path="$art/failure-$ordinal.json"
  local attempt_id ended_at output_started failure_json tmp
  [[ -f "$attempt_path" ]] || return 1
  attempt_id="$(jq -r '.attempt_id' "$attempt_path")"
  ended_at="$(jq -r '.ended_at' "$attempt_path")"
  output_started="$(jq -r '.output_started' "$attempt_path")"
  failure_json="$(jq -cn \
    --arg id "${RUN_ID}-${executor}-failure-${ordinal}" --arg run "$RUN_ID" \
    --arg attempt "$attempt_id" --arg ts "$ended_at" --arg class "$failure_class" \
    --arg code "$provider_code" --arg message "$message" \
    --argjson output_started "$output_started" '
    {schema:"legion.failure.v1",failure_id:$id,run_id:$run,attempt_id:$attempt,ts:$ts,
     class:$class,provider_code:(if $code=="" then null else $code end),retryable:false,
     output_started:$output_started,message:(if $message=="" then null else $message end)}')"
  printf '%s\n' "$failure_json" > "$failure_path.tmp.$$"
  chmod 600 "$failure_path.tmp.$$" 2>/dev/null || true
  mv -f "$failure_path.tmp.$$" "$failure_path"
  cp "$failure_path" "$art/failure.json"
  tmp="$attempt_path.tmp.$$"
  jq --argjson failure "$failure_json" \
    '.terminal_status="failed" | .failure=$failure' "$attempt_path" > "$tmp"
  chmod 600 "$tmp" 2>/dev/null || true
  mv -f "$tmp" "$attempt_path"
  cp "$attempt_path" "$art/attempt.json"
  LEGION_ADAPTER_ATTEMPT_PATH="$attempt_path"
  LEGION_ADAPTER_FAILURE_PATH="$failure_path"
}

legion_adapter_output_started_file() {
  [[ -s "$1" ]] && grep -q '[^[:space:]]' "$1" 2>/dev/null
}
