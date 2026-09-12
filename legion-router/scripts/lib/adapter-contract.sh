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
LEGION_ADAPTER_LAUNCH_GATE_SIGNAL_ACTIVE=0
LEGION_ADAPTER_LAUNCH_GATE_SIGNAL_BUSY=0
LEGION_ADAPTER_LAUNCH_GATE_SIGNAL_FAILED=0
LEGION_ADAPTER_LAUNCH_GATE_SIGNAL_GATE=""
LEGION_ADAPTER_LAUNCH_GATE_SIGNAL_TOKEN=""
LEGION_ADAPTER_LAUNCH_GATE_SIGNAL_SUPERVISOR_PID=""
LEGION_ADAPTER_LAUNCH_GATE_SIGNAL_DECISION_TEMP=""
LEGION_ADAPTER_LAUNCH_GATE_SIGNAL_FD_OPEN=0
LEGION_ADAPTER_LAUNCH_GATE_PATH=""
LEGION_ADAPTER_LAUNCH_GATE_TOKEN=""
LEGION_ADAPTER_LAUNCH_GATE_OUTCOME=""

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

# A supervisor timeout before Popen necessarily uses the no-launch
# `launch_failed` shape, because there is no child whose terminal state could
# be `timed_out`.  The authenticated supervisor exit code and its bounded
# deadline reason distinguish that case from an unavailable executable.  Keep
# this predicate ahead of generic launch-failure handling so an inherited
# absolute lease cannot silently trigger provider fallback.
legion_adapter_supervisor_timed_out_before_launch() {
  local status_file="$1" supervisor_rc="${2:-}"
  [[ "$supervisor_rc" == 124 ]] || return 1
  legion_adapter_supervisor_launch_failed "$status_file" || return 1
  jq -e '
    .reason == "inherited child lease deadline expired before launch"
    or .reason == "inherited child lease deadline expired during launch setup"
    or .reason == "pre-launch supervisor gate timed out before launch authorization"
  ' "$status_file" >/dev/null 2>&1
}

# Persist the same strict no-launch shape as the process supervisor when a
# foreground adapter receives a signal at its final shell gate, before Popen
# and before provider-attempt accounting are armed. The caller remains
# responsible for retaining containment if this trusted write fails.
legion_adapter_write_final_gate_no_launch() {
  local status_file="$1" max_runtime="$2" signum="$3" directory temp
  [[ -n "$status_file" && "$max_runtime" =~ ^[1-9][0-9]*$ \
      && "$signum" =~ ^(1|2|15)$ ]] || return 1
  directory="${status_file%/*}"
  [[ "$directory" != "$status_file" && -d "$directory" && ! -L "$directory" ]] || return 1
  [[ ! -e "$status_file" && ! -L "$status_file" ]] || return 1
  temp="$(mktemp "$directory/.final-gate-lease.XXXXXX")" || return 1
  if ! jq -cn --argjson runtime "$max_runtime" --arg signum "$signum" '
      {schema:"legion.child-execution-lease.v1",status:"launch_failed",
       reason:("provider launch cancelled by signal " + $signum
               + " at final pre-launch gate; no provider launched"),
       max_runtime_seconds:$runtime}
    ' > "$temp"; then
    rm -f "$temp"
    return 1
  fi
  chmod 600 "$temp" || { rm -f "$temp"; return 1; }
  # Publish without replacing a raced or pre-existing claimant. A hard link in
  # the same trusted directory is atomic and portable across Darwin/Linux.
  if ! ln "$temp" "$status_file"; then
    rm -f "$temp"
    return 1
  fi
  rm -f "$temp"
  legion_adapter_supervisor_launch_failed "$status_file"
}

legion_adapter_prepare_supervisor_launch_gate() {
  local gate_path="$1"
  [[ -n "$gate_path" && ! -e "$gate_path" && ! -L "$gate_path" \
      && -d "${gate_path%/*}" && ! -L "${gate_path%/*}" ]] || return 1
  LEGION_ADAPTER_LAUNCH_GATE_PATH="$gate_path"
  LEGION_ADAPTER_LAUNCH_GATE_TOKEN="$(python3 -c 'import secrets; print(secrets.token_hex(32))')" \
    || return 1
  LEGION_ADAPTER_LAUNCH_GATE_OUTCOME=""
}

# Record a signal during the shell-to-supervisor launch handshake. The normal
# path and this trap write to one already-open FIFO using Bash builtins. Bash
# serializes trap execution with builtin execution. Keep the trap armed until
# the arbiter has returned: after the writer closes, a signal must at least
# terminate the supervisor instead of silently permitting a pending `go`.
legion_adapter_record_launch_signal() {
  local pending_name="$1" signum="$2" normalized="$2"
  case "$normalized" in HUP) normalized=1 ;; INT) normalized=2 ;; TERM) normalized=15 ;; esac
  printf -v "$pending_name" '%s' "$signum"
  [[ "$LEGION_ADAPTER_LAUNCH_GATE_SIGNAL_ACTIVE" -eq 1 ]] || return 0
  [[ "$normalized" =~ ^(1|2|15)$ ]] || {
    LEGION_ADAPTER_LAUNCH_GATE_SIGNAL_FAILED=1
    return 0
  }
  # A repeated signal can interrupt the commands below. The first handler owns
  # publication; later handlers still update the caller's pending signal.
  [[ "$LEGION_ADAPTER_LAUNCH_GATE_SIGNAL_BUSY" -eq 0 ]] || return 0
  LEGION_ADAPTER_LAUNCH_GATE_SIGNAL_BUSY=1
  if [[ "$LEGION_ADAPTER_LAUNCH_GATE_SIGNAL_FD_OPEN" -eq 1 ]]; then
    printf 'cancel:%s\n' "$normalized" >&9 || LEGION_ADAPTER_LAUNCH_GATE_SIGNAL_FAILED=1
    [[ "${LEGION_ADAPTER_LAUNCH_GATE_SIGNAL_SEALED:-0}" -ne 1 ]] \
      || LEGION_ADAPTER_LAUNCH_GATE_SIGNAL_FAILED=1
  else
    LEGION_ADAPTER_LAUNCH_GATE_SIGNAL_FAILED=1
  fi
  if [[ "$LEGION_ADAPTER_LAUNCH_GATE_SIGNAL_FAILED" -eq 1 ]]; then
    kill -TERM "$LEGION_ADAPTER_LAUNCH_GATE_SIGNAL_SUPERVISOR_PID" 2>/dev/null || true
  fi
  LEGION_ADAPTER_LAUNCH_GATE_SIGNAL_BUSY=0
}

legion_adapter_close_launch_signal_window() {
  LEGION_ADAPTER_LAUNCH_GATE_SIGNAL_ACTIVE=0
  LEGION_ADAPTER_LAUNCH_GATE_SIGNAL_BUSY=0
  LEGION_ADAPTER_LAUNCH_GATE_SIGNAL_FAILED=0
  LEGION_ADAPTER_LAUNCH_GATE_SIGNAL_GATE=""
  LEGION_ADAPTER_LAUNCH_GATE_SIGNAL_TOKEN=""
  LEGION_ADAPTER_LAUNCH_GATE_SIGNAL_SUPERVISOR_PID=""
  LEGION_ADAPTER_LAUNCH_GATE_SIGNAL_DECISION_TEMP=""
  LEGION_ADAPTER_LAUNCH_GATE_SIGNAL_FD_OPEN=0
  LEGION_ADAPTER_LAUNCH_GATE_SIGNAL_SEALED=0
}

legion_adapter_launch_gate_decision_arbiter() {
  local gate="$1" fifo="$2" listener="$3" token="$4" supervisor_pid="$5"
  python3 - "$gate" "$fifo" "$listener" "$token" "$supervisor_pid" <<'PY'
import json
import os
import select
import stat
import sys
import tempfile
import time

gate, fifo, listener, token, supervisor_pid_text = sys.argv[1:]
supervisor_pid = int(supervisor_pid_text)

def fail(message):
    print(f"launch-gate decision arbiter: {message}", file=sys.stderr)
    raise SystemExit(70)

fifo_flags = os.O_RDWR | getattr(os, "O_NONBLOCK", 0) | getattr(os, "O_NOFOLLOW", 0)
fifo_descriptor = os.open(fifo, fifo_flags)
fifo_info = os.fstat(fifo_descriptor)
fifo_path_info = os.stat(fifo, follow_symlinks=False)
if (not stat.S_ISFIFO(fifo_info.st_mode) or fifo_info.st_nlink != 1
        or (fifo_info.st_dev, fifo_info.st_ino)
        != (fifo_path_info.st_dev, fifo_path_info.st_ino)):
    fail("unsafe decision FIFO")

flags = os.O_RDONLY
if hasattr(os, "O_NOFOLLOW"):
    flags |= os.O_NOFOLLOW
descriptor = os.open(gate, flags)
try:
    opened = os.fstat(descriptor)
    if not stat.S_ISREG(opened.st_mode) or opened.st_nlink != 1 or opened.st_size > 4096:
        fail("unsafe ready receipt")
    raw = os.read(descriptor, 4097)
    current = os.fstat(descriptor)
    path_stat = os.stat(gate, follow_symlinks=False)
    if ((opened.st_dev, opened.st_ino) != (current.st_dev, current.st_ino)
            or (opened.st_dev, opened.st_ino) != (path_stat.st_dev, path_stat.st_ino)
            or opened.st_mtime_ns != current.st_mtime_ns
            or opened.st_ctime_ns != current.st_ctime_ns):
        fail("ready receipt changed while reading")
finally:
    os.close(descriptor)
try:
    ready = json.loads(raw)
except (ValueError, UnicodeDecodeError):
    fail("malformed ready receipt")
if (not isinstance(ready, dict)
        or set(ready) != {"schema", "status", "token", "supervisor_pid"}
        or ready != {"schema": "legion.child-launch-gate.v1", "status": "ready",
                     "token": token, "supervisor_pid": supervisor_pid}):
    fail("unauthenticated ready receipt")

# On Darwin a FIFO opened read/write by the shell can lose bytes written
# before the arbiter opens its own descriptor. Publish a one-use listener
# acknowledgement only after opening and authenticating the ready receipt.
listener_fd = os.open(listener, os.O_WRONLY | os.O_CREAT | os.O_EXCL |
                      getattr(os, "O_NOFOLLOW", 0), 0o600)
os.close(listener_fd)

with os.fdopen(fifo_descriptor, "rb", buffering=0) as source:
    raw_decisions = bytearray()
    # The shell opens the FIFO read/write so its open never waits for an
    # arbiter that exited before this point. Such a self-reader prevents EOF;
    # use an explicit bounded terminal record instead.
    deadline = time.monotonic() + 10
    while len(raw_decisions) <= 128:
        if time.monotonic() >= deadline:
            fail("decision stream timed out")
        ready, _, _ = select.select([source], [], [], 0.1)
        if not ready:
            continue
        chunk = os.read(source.fileno(), 1)
        if not chunk:
            fail("decision FIFO closed unexpectedly")
        raw_decisions.extend(chunk)
        if raw_decisions.endswith(b"done\n"):
            break
if len(raw_decisions) > 128:
    fail("decision stream exceeded bound")
lines = raw_decisions.decode("ascii", "strict").splitlines()
if len(lines) < 2 or lines[-1] != "done":
    fail("decision stream was empty")
lines.pop()
allowed = {"go", "cancel:1", "cancel:2", "cancel:15"}
if any(line not in allowed for line in lines):
    fail("invalid decision")
# Do not expose `go` until the explicit terminal record closes the shell-side
# decision window; a trap after the provisional go write can still cancel.
cancellations = [line for line in lines if line.startswith("cancel:")]
if cancellations:
    cancelled = cancellations[0]
    payload = {"schema": "legion.child-launch-gate.v1", "status": "cancel",
               "token": token, "supervisor_pid": supervisor_pid,
               "signal": int(cancelled.partition(":")[2])}
elif lines == ["go"]:
    payload = {"schema": "legion.child-launch-gate.v1", "status": "go",
               "token": token, "supervisor_pid": supervisor_pid}
else:
    fail("duplicate go decision")

directory = os.path.dirname(gate)
fd, temporary = tempfile.mkstemp(prefix=".launch-gate-decision.", dir=directory)
try:
    with os.fdopen(fd, "w", encoding="utf-8") as destination:
        json.dump(payload, destination, separators=(",", ":"))
        destination.write("\n")
        destination.flush()
        os.fsync(destination.fileno())
    os.chmod(temporary, 0o600)
    os.replace(temporary, gate)
    directory_fd = os.open(directory, os.O_RDONLY)
    try:
        os.fsync(directory_fd)
    finally:
        os.close(directory_fd)
finally:
    try:
        os.unlink(temporary)
    except FileNotFoundError:
        pass
PY
}

legion_adapter_complete_supervisor_launch_gate() {
  local supervisor_pid="$1" lease_path="$2" pending_name="$3"
  local gate="$LEGION_ADAPTER_LAUNCH_GATE_PATH" token="$LEGION_ADAPTER_LAUNCH_GATE_TOKEN"
  local pending="" decision=go fifo="" listener="" arbiter_pid="" arbiter_rc=0 i sleep_bin=/bin/sleep
  # Do not let stale publication state from an interrupted or reused shell
  # influence this handshake, including early polling failures below.
  legion_adapter_close_launch_signal_window
  [[ -x "$sleep_bin" ]] || sleep_bin="$(command -v sleep 2>/dev/null || true)"
  [[ -n "$sleep_bin" ]] || return 0
  LEGION_ADAPTER_LAUNCH_GATE_OUTCOME=containment_failed
  for ((i = 0; i < 500; i++)); do
    if jq -e --arg token "$token" --argjson pid "$supervisor_pid" '
        .schema == "legion.child-launch-gate.v1" and .status == "ready"
        and .token == $token and .supervisor_pid == $pid
        and ((keys_unsorted - ["schema","status","token","supervisor_pid"]) | length == 0)
      ' "$gate" >/dev/null 2>&1; then
      break
    fi
    if ! kill -0 "$supervisor_pid" 2>/dev/null; then
      legion_adapter_supervisor_launch_failed "$lease_path" \
        && LEGION_ADAPTER_LAUNCH_GATE_OUTCOME=launch_failed
      return 0
    fi
    "$sleep_bin" 0.02
  done
  jq -e --arg token "$token" --argjson pid "$supervisor_pid" '
    .schema == "legion.child-launch-gate.v1" and .status == "ready"
    and .token == $token and .supervisor_pid == $pid
    and ((keys_unsorted - ["schema","status","token","supervisor_pid"]) | length == 0)
  ' "$gate" >/dev/null 2>&1 || return 0
  # fd 9 is reserved only for the short decision window. Refuse to clobber an
  # inherited descriptor because its semantics are outside this contract.
  if { : >&9; } 2>/dev/null; then
    legion_adapter_close_launch_signal_window
    return 0
  fi
  fifo="$(python3 - "${gate%/*}" <<'PY'
import os
import secrets
import sys

directory = sys.argv[1]
for _ in range(64):
    candidate = os.path.join(
        directory, ".launch-gate-decision-fifo." + secrets.token_hex(12)
    )
    try:
        os.mkfifo(candidate, 0o600)
    except FileExistsError:
        continue
    print(candidate)
    raise SystemExit(0)
raise SystemExit(1)
PY
)" || {
    legion_adapter_close_launch_signal_window
    return 0
  }
  listener="${fifo}.listener"
  legion_adapter_launch_gate_decision_arbiter \
    "$gate" "$fifo" "$listener" "$token" "$supervisor_pid" &
  arbiter_pid=$!
  for ((i = 0; i < 500; i++)); do
    [[ ! -e "$listener" ]] || break
    kill -0 "$arbiter_pid" 2>/dev/null || break
    "$sleep_bin" 0.02
  done
  if [[ ! -f "$listener" ]]; then
    kill -TERM "$arbiter_pid" 2>/dev/null || true
    wait "$arbiter_pid" 2>/dev/null || true
    rm -f "$fifo" "$listener"
    legion_adapter_close_launch_signal_window
    return 0
  fi
  # O_RDWR opens a FIFO without waiting for an arbiter reader. If ready
  # validation made the arbiter exit, this cannot suspend the shell forever.
  if ! exec 9<>"$fifo"; then
    kill -TERM "$arbiter_pid" 2>/dev/null || true
    wait "$arbiter_pid" 2>/dev/null || true
    rm -f "$fifo" "$listener"
    legion_adapter_close_launch_signal_window
    return 0
  fi
  LEGION_ADAPTER_LAUNCH_GATE_SIGNAL_ACTIVE=1
  LEGION_ADAPTER_LAUNCH_GATE_SIGNAL_FAILED=0
  LEGION_ADAPTER_LAUNCH_GATE_SIGNAL_GATE="$gate"
  LEGION_ADAPTER_LAUNCH_GATE_SIGNAL_TOKEN="$token"
  LEGION_ADAPTER_LAUNCH_GATE_SIGNAL_SUPERVISOR_PID="$supervisor_pid"
  LEGION_ADAPTER_LAUNCH_GATE_SIGNAL_DECISION_TEMP=""
  LEGION_ADAPTER_LAUNCH_GATE_SIGNAL_FD_OPEN=1
  LEGION_ADAPTER_LAUNCH_GATE_SIGNAL_SEALED=0
  pending="${!pending_name:-}"
  case "$pending" in
    HUP) pending=1 ;;
    INT) pending=2 ;;
    TERM) pending=15 ;;
  esac
  [[ -z "$pending" ]] || decision=cancel
  if [[ "$decision" == cancel ]]; then
    printf 'cancel:%s\n' "$pending" >&9 || LEGION_ADAPTER_LAUNCH_GATE_SIGNAL_FAILED=1
  else
    printf 'go\n' >&9 || LEGION_ADAPTER_LAUNCH_GATE_SIGNAL_FAILED=1
  fi
  LEGION_ADAPTER_LAUNCH_GATE_SIGNAL_SEALED=1
  printf 'done\n' >&9 || LEGION_ADAPTER_LAUNCH_GATE_SIGNAL_FAILED=1
  LEGION_ADAPTER_LAUNCH_GATE_SIGNAL_FD_OPEN=0
  exec 9>&-
  wait "$arbiter_pid" || arbiter_rc=$?
  if [[ "$arbiter_rc" -gt 128 ]]; then
    # A trapped signal can interrupt Bash's wait without reaping the arbiter.
    # Never leave a pending arbiter free to publish `go` after we return.
    kill -TERM "$arbiter_pid" 2>/dev/null || true
    wait "$arbiter_pid" 2>/dev/null || true
  fi
  # A signal delivered while `wait` was pending still belongs to this launch
  # decision. Do not clear ACTIVE until the arbiter's publication is resolved.
  LEGION_ADAPTER_LAUNCH_GATE_SIGNAL_ACTIVE=0
  rm -f "$fifo" "$listener"
  if [[ "$LEGION_ADAPTER_LAUNCH_GATE_SIGNAL_FAILED" -eq 1 || "$arbiter_rc" -ne 0 ]]; then
    kill -TERM "$supervisor_pid" 2>/dev/null || true
    legion_adapter_close_launch_signal_window
    return 0
  fi
  for ((i = 0; i < 500; i++)); do
    if jq -e --arg token "$token" --argjson pid "$supervisor_pid" '
        .schema == "legion.child-launch-gate.v1" and .status == "started"
        and .token == $token and .supervisor_pid == $pid
        and (.child_pid | type == "number" and . >= 1 and . == floor)
        and ((keys_unsorted - ["schema","status","token","supervisor_pid","child_pid"]) | length == 0)
      ' "$gate" >/dev/null 2>&1; then
      LEGION_ADAPTER_LAUNCH_GATE_OUTCOME=started
      legion_adapter_close_launch_signal_window
      return 0
    fi
    if legion_adapter_supervisor_launch_failed "$lease_path"; then
      LEGION_ADAPTER_LAUNCH_GATE_OUTCOME=launch_failed
      legion_adapter_close_launch_signal_window
      return 0
    fi
    if legion_adapter_supervisor_cleanup_failed_before_launch "$lease_path"; then
      legion_adapter_close_launch_signal_window
      return 0
    fi
    if ! kill -0 "$supervisor_pid" 2>/dev/null; then
      legion_adapter_supervisor_launch_failed "$lease_path" \
        && LEGION_ADAPTER_LAUNCH_GATE_OUTCOME=launch_failed
      legion_adapter_close_launch_signal_window
      return 0
    fi
    "$sleep_bin" 0.02
  done
  legion_adapter_close_launch_signal_window
}

# A malformed, unauthenticated, or stalled launch gate leaves the provider
# launch state unknowable. After the adapter has terminated and waited for the
# supervisor, replace any weaker sidecar with a strict containment receipt and
# emit a machine-readable terminal envelope. Unknown is intentional here: the
# failed gate cannot prove either spend or no-spend.
legion_adapter_write_launch_gate_containment_lease() {
  local lease_path="$1" gate_path="$2" worktree="$3" max_runtime="$4"
  local directory temp="" reason
  directory="${lease_path%/*}"
  reason="supervisor launch-gate authentication or handshake failed; launch state unresolved (gate: $gate_path; evidence: $lease_path; worktree retained: $worktree)"
  if [[ -n "$lease_path" && "$directory" != "$lease_path" && -d "$directory" \
      && ! -L "$directory" && ! -L "$lease_path" \
      && "$max_runtime" =~ ^[1-9][0-9]*$ ]] \
      && temp="$(mktemp "$directory/.launch-gate-containment.XXXXXX")" \
      && jq -cn --arg reason "$reason" --argjson runtime "$max_runtime" '
      {schema:"legion.child-execution-lease.v1",status:"cleanup_failed",
       reason:$reason,max_runtime_seconds:$runtime}
    ' > "$temp" \
      && chmod 600 "$temp" \
      && mv -f "$temp" "$lease_path" \
      && legion_adapter_supervisor_cleanup_failed "$lease_path"; then
    return 0
  else
    [[ -z "$temp" ]] || rm -f "$temp"
    return 1
  fi
}

legion_adapter_terminalize_launch_gate_containment() {
  local executor="$1" model="$2" run_id="$3" preflight="$4"
  local lease_path="$5" gate_path="$6" worktree="$7" max_runtime="$8"
  local reason lease_receipt=""
  reason="supervisor launch-gate authentication or handshake failed; launch state unresolved (gate: $gate_path; evidence: $lease_path; worktree retained: $worktree)"
  if legion_adapter_write_launch_gate_containment_lease \
      "$lease_path" "$gate_path" "$worktree" "$max_runtime"; then
    lease_receipt="$lease_path"
  else
    reason="$reason; strict containment sidecar could not be persisted"
  fi
  jq -cn --arg run "$run_id" --arg executor "$executor" --arg model "$model" \
    --arg reason "$reason" --arg worktree "$worktree" --arg preflight "$preflight" \
    --arg lease "$lease_receipt" '
      {run_id:$run,status:"containment_failed",executor:$executor,model:$model,
       result:$reason,reason:$reason,worktree:$worktree,
       usage:null,tokens:null,usage_status:"unknown",
       cost_usd:null,cost_status:"unknown",
       preflight_receipt:(if $preflight=="" then null else $preflight end),
       attempt_receipt:null,failure_receipt:null,
       lease_receipt:(if $lease=="" then null else $lease end)}
    '
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
  local root validation_root preflight tmp alias_tmp rc=0 receipt_valid=1
  root="$(legion_adapter_contract_root)"
  validation_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
  preflight="$root/legion-router/bin/legion-preflight"
  LEGION_ADAPTER_PREFLIGHT_PATH="$art/$executor-preflight.json"
  mkdir -p "$art"
  [[ -d "$art" && ! -L "$art" \
      && ! -L "$LEGION_ADAPTER_PREFLIGHT_PATH" \
      && ! -L "$art/preflight.json" \
      && ( ! -e "$LEGION_ADAPTER_PREFLIGHT_PATH" || -f "$LEGION_ADAPTER_PREFLIGHT_PATH" ) \
      && ( ! -e "$art/preflight.json" || -f "$art/preflight.json" ) ]] || {
    LEGION_ADAPTER_PREFLIGHT_STATUS=invalid
    LEGION_ADAPTER_PREFLIGHT_REASON="unsafe preflight receipt leaf"
    return 1
  }
  tmp="$(mktemp "$art/.${executor}-preflight.XXXXXX")" || return 1
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
  fi
  if ! PYTHONPATH="$validation_root/legion-observability/scripts" python3 - \
      "$tmp" "$executor" "$model" "$sandbox" "$effort" "$transport" "$consent" \
      2>/dev/null <<'PY'
import sys
from legion_preflight import validate_preflight_receipt_file

path, executor, model, sandbox, effort, transport, consent = sys.argv[1:]
validate_preflight_receipt_file(
    path, executor=executor, model=model or None, sandbox=sandbox or None,
    read_mode="provider-tools", task_transport=transport or None,
    effort=effort or None, explicit_consent=consent == "1",
)
PY
  then
    receipt_valid=0
    rc=1
    local invalid_tmp
    invalid_tmp="$(mktemp "$art/.invalid-preflight.XXXXXX")" || { rm -f "$tmp"; return 1; }
    if jq -c '.status="invalid"
        | .reason="shared Legion preflight returned malformed or incomplete evidence"' \
        "$tmp" > "$invalid_tmp" 2>/dev/null; then
      chmod 600 "$invalid_tmp" || { rm -f "$tmp" "$invalid_tmp"; return 1; }
      python3 - "$invalid_tmp" "$tmp" <<'PY'
import os
import sys
os.replace(sys.argv[1], sys.argv[2])
PY
    else
      rm -f "$invalid_tmp"
    fi
  fi
  chmod 600 "$tmp" || { rm -f "$tmp"; return 1; }
  alias_tmp="$(mktemp "$art/.preflight-alias.XXXXXX")" || { rm -f "$tmp"; return 1; }
  if ! cp "$tmp" "$alias_tmp" || ! chmod 600 "$alias_tmp" \
      || ! python3 - "$tmp" "$LEGION_ADAPTER_PREFLIGHT_PATH" \
          "$alias_tmp" "$art/preflight.json" <<'PY'
import os
import sys

source, destination, alias_source, alias_destination = sys.argv[1:]
os.replace(source, destination)
os.replace(alias_source, alias_destination)
directory = os.open(os.path.dirname(destination), os.O_RDONLY)
try:
    os.fsync(directory)
finally:
    os.close(directory)
PY
  then
    rm -f "$tmp" "$alias_tmp"
    LEGION_ADAPTER_PREFLIGHT_STATUS=invalid
    LEGION_ADAPTER_PREFLIGHT_REASON="unable to publish preflight evidence safely"
    return 1
  fi
  if [[ "$receipt_valid" -ne 1 ]]; then
    LEGION_ADAPTER_PREFLIGHT_STATUS=invalid
    LEGION_ADAPTER_PREFLIGHT_REASON="shared Legion preflight returned malformed or incomplete evidence"
    LEGION_ADAPTER_CONFIG_IDENTITY=""
    LEGION_ADAPTER_PREFLIGHT_CACHE_KEY=""
    return 1
  fi
  LEGION_ADAPTER_PREFLIGHT_STATUS="$(jq -r '.status // "invalid"' "$LEGION_ADAPTER_PREFLIGHT_PATH" 2>/dev/null || printf invalid)"
  # shellcheck disable=SC2034
  LEGION_ADAPTER_PREFLIGHT_REASON="$(jq -r '.reason // "preflight evidence is invalid"' "$LEGION_ADAPTER_PREFLIGHT_PATH" 2>/dev/null || printf 'preflight evidence is invalid')"
  LEGION_ADAPTER_CONFIG_IDENTITY="$(jq -r '.identity.config_sha256 // empty' "$LEGION_ADAPTER_PREFLIGHT_PATH" 2>/dev/null || true)"
  LEGION_ADAPTER_PREFLIGHT_CACHE_KEY="$(jq -r '.cache.key // empty' "$LEGION_ADAPTER_PREFLIGHT_PATH" 2>/dev/null || true)"
  [[ "$rc" -eq 0 && "$LEGION_ADAPTER_PREFLIGHT_STATUS" == supported ]]
}

# Classify a failed shared preflight without allowing its public top-level
# `unavailable` status to erase a terminal version-probe outcome. The embedded
# supervisor lease is authoritative only when its complete no-launch/timeout
# shape agrees with the probe fields. Any contradictory or partial provenance
# is containment failure, never permission to spend through another route.
legion_adapter_preflight_failure_disposition() {
  local receipt="$1" status probe
  [[ -f "$receipt" && ! -L "$receipt" ]] || { printf containment_failed; return 0; }
  status="$(jq -r 'if .schema == "legion.preflight.v1" then (.status // "") else "" end' \
    "$receipt" 2>/dev/null || true)"
  case "$status" in
    incompatible|untested) printf refused; return 0 ;;
    unavailable) ;;
    *) printf containment_failed; return 0 ;;
  esac
  probe="$(jq -r '.compatibility.version.probe_status // empty' "$receipt" 2>/dev/null || true)"
  if [[ -z "$probe" ]]; then
    printf unavailable
    return 0
  fi
  case "$probe" in
    timed_out)
      if jq -e '
        .schema == "legion.preflight.v1" and .status == "unavailable"
        and .identity == null
        and (.compatibility.version | type == "object")
        and .compatibility.version.probe_status == "timed_out"
        and (.compatibility.version.probe_reason | type == "string" and length > 0)
        and (.compatibility.version.probe_lease | type == "object")
        and .compatibility.version.probe_lease.schema == "legion.child-execution-lease.v1"
        and .compatibility.version.probe_reason == .compatibility.version.probe_lease.reason
        and (.compatibility.version.probe_lease.max_runtime_seconds
          | type == "number" and . >= 1 and . == floor)
        and (
          (.compatibility.version.probe_lease.status == "launch_failed"
            and (.compatibility.version.probe_lease.reason | ascii_downcase | contains("deadline"))
            and ((.compatibility.version.probe_lease | keys_unsorted)
              - ["schema","status","reason","max_runtime_seconds"] | length == 0))
          or
          (.compatibility.version.probe_lease.status == "timed_out"
            and (.compatibility.version.probe_lease.reason | ascii_downcase
              | test("lease.*expired|timed out"))
            and ((.compatibility.version.probe_lease | keys_unsorted)
              - ["schema","status","reason","max_runtime_seconds"] | length == 0))
        )
      ' "$receipt" >/dev/null 2>&1; then
        printf timed_out
      else
        printf containment_failed
      fi
      ;;
    launch_failed)
      if jq -e '
        .schema == "legion.preflight.v1" and .status == "unavailable"
        and .identity == null
        and .compatibility.version.probe_status == "launch_failed"
        and (.compatibility.version.probe_reason | type == "string" and length > 0)
        and (.compatibility.version.probe_reason | ascii_downcase | contains("deadline") | not)
        and (.compatibility.version.probe_lease | type == "object")
        and .compatibility.version.probe_lease.schema == "legion.child-execution-lease.v1"
        and (.compatibility.version.probe_lease.max_runtime_seconds
          | type == "number" and . >= 1 and . == floor)
        and (
          (.compatibility.version.probe_lease.status == "launch_failed"
            and .compatibility.version.probe_reason == .compatibility.version.probe_lease.reason
            and ((.compatibility.version.probe_lease | keys_unsorted)
              - ["schema","status","reason","max_runtime_seconds"] | length == 0))
          or
          (.compatibility.version.probe_reason
            == "executor binary disappeared or changed during version probe"
            and (
              (.compatibility.version.probe_lease.status == "completed"
                and .compatibility.version.probe_lease.reason == "child completed"
                and (.compatibility.version.probe_lease.child_exit_code
                  | type == "number" and . >= 0 and . <= 255 and . == floor)
                and ((.compatibility.version.probe_lease | keys_unsorted)
                  - ["schema","status","reason","max_runtime_seconds","child_exit_code"]
                  | length == 0))
              or
              (.compatibility.version.probe_lease.status == "launch_failed"
                and (.compatibility.version.probe_lease.reason
                  | startswith("child launch failed: command not found: "))
                and ((.compatibility.version.probe_lease | keys_unsorted)
                  - ["schema","status","reason","max_runtime_seconds"]
                  | length == 0))
            ))
        )
      ' "$receipt" >/dev/null 2>&1; then
        printf launch_failed
      else
        printf containment_failed
      fi
      ;;
    *) printf containment_failed ;;
  esac
}

legion_adapter_publish_attempt_receipts() {
  local art="$1" attempt_tmp="$2" attempt_name="$3" failure_tmp="$4" failure_name="$5"
  python3 - "$art" "$attempt_tmp" "$attempt_name" "$failure_tmp" "$failure_name" <<'PY'
import os
import secrets
import stat
import sys

art, attempt_tmp, attempt_name, failure_tmp, failure_name = sys.argv[1:]
flags = os.O_RDONLY | getattr(os, "O_DIRECTORY", 0) | getattr(os, "O_NOFOLLOW", 0)
directory = os.open(art, flags)
linked_failure = False
linked_attempt = False

def check_leaf(name, *, must_exist=False):
    try:
        info = os.stat(name, dir_fd=directory, follow_symlinks=False)
    except FileNotFoundError:
        if must_exist:
            raise
        return None
    if not stat.S_ISREG(info.st_mode) or info.st_nlink != 1:
        raise OSError(f"unsafe receipt leaf: {name}")
    return info

def copy_alias(source, alias):
    temporary = ".receipt-alias." + secrets.token_hex(16)
    source_fd = os.open(source, os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0), dir_fd=directory)
    target_fd = None
    try:
        target_fd = os.open(
            temporary, os.O_WRONLY | os.O_CREAT | os.O_EXCL | getattr(os, "O_NOFOLLOW", 0),
            0o600, dir_fd=directory,
        )
        while True:
            chunk = os.read(source_fd, 65536)
            if not chunk:
                break
            view = memoryview(chunk)
            while view:
                view = view[os.write(target_fd, view):]
        os.fsync(target_fd)
        os.close(target_fd)
        target_fd = None
        # os.replace cannot follow a racing symlink, but refuse a link already
        # present at this decision point rather than normalizing hostile state.
        check_leaf(alias)
        os.replace(temporary, alias, src_dir_fd=directory, dst_dir_fd=directory)
    finally:
        os.close(source_fd)
        if target_fd is not None:
            os.close(target_fd)
        try:
            os.unlink(temporary, dir_fd=directory)
        except FileNotFoundError:
            pass

try:
    root = os.fstat(directory)
    current = os.stat(art, follow_symlinks=False)
    if (not stat.S_ISDIR(current.st_mode) or
            (root.st_dev, root.st_ino) != (current.st_dev, current.st_ino)):
        raise OSError("receipt directory changed")
    for name in (attempt_tmp, attempt_name, "attempt.json"):
        if "/" in name or name in {"", ".", ".."}:
            raise OSError("unsafe receipt name")
    check_leaf(attempt_tmp, must_exist=True)
    if check_leaf(attempt_name) is not None:
        raise FileExistsError("numbered attempt is immutable")
    check_leaf("attempt.json")
    if failure_tmp:
        for name in (failure_tmp, failure_name, "failure.json"):
            if "/" in name or name in {"", ".", ".."}:
                raise OSError("unsafe failure name")
        check_leaf(failure_tmp, must_exist=True)
        if check_leaf(failure_name) is not None:
            raise FileExistsError("numbered failure is immutable")
        check_leaf("failure.json")
        os.link(failure_tmp, failure_name, src_dir_fd=directory, dst_dir_fd=directory,
                follow_symlinks=False)
        linked_failure = True
    else:
        check_leaf("failure.json")
    os.link(attempt_tmp, attempt_name, src_dir_fd=directory, dst_dir_fd=directory,
            follow_symlinks=False)
    linked_attempt = True
    # The exclusive temporary and numbered link now share an inode. Drop the
    # temporary before aliases so indexed readers see a singly linked receipt.
    os.unlink(attempt_tmp, dir_fd=directory)
    if failure_tmp:
        os.unlink(failure_tmp, dir_fd=directory)
        copy_alias(failure_name, "failure.json")
    else:
        try:
            os.unlink("failure.json", dir_fd=directory)
        except FileNotFoundError:
            pass
    copy_alias(attempt_name, "attempt.json")
    os.fsync(directory)
except OSError as error:
    if linked_failure and not linked_attempt:
        try:
            os.unlink(failure_name, dir_fd=directory)
        except OSError:
            pass
    print(f"legion adapter receipt: {error}", file=sys.stderr)
    raise SystemExit(1)
finally:
    os.close(directory)
PY
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
  local tmp failure_tmp="" failure_json=null usage_json=null cost_json=null
  [[ -d "$art" && ! -L "$art" ]] || return 1
  tmp="$(mktemp "$art/.attempt-$ordinal.XXXXXX")" || return 1

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
    failure_tmp="$(mktemp "$art/.failure-$ordinal.XXXXXX")" || { rm -f "$tmp"; return 1; }
    printf '%s\n' "$failure_json" > "$failure_tmp" || { rm -f "$tmp" "$failure_tmp"; return 1; }
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
     child_attempt_ids:[],reconciliation:null}' > "$tmp" || {
      rm -f "$tmp" "$failure_tmp"
      return 1
    }
  if ! legion_adapter_publish_attempt_receipts "$art" "${tmp##*/}" "${attempt_path##*/}" \
      "${failure_tmp##*/}" "${failure_path##*/}"; then
    rm -f "$tmp" "$failure_tmp"
    return 1
  fi
  # shellcheck disable=SC2034
  LEGION_ADAPTER_FAILURE_PATH="${failure_tmp:+$failure_path}"
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

legion_adapter_span_date() {
  if [[ -n "${LEGION_ADAPTER_SPAN_DATE:-}" ]]; then
    [[ "$LEGION_ADAPTER_SPAN_DATE" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]] || return 1
    printf '%s\n' "$LEGION_ADAPTER_SPAN_DATE"
  else
    date -u +%F
  fi
}

legion_adapter_prepare_provider_span() {
  local attempt_path="$1"
  [[ -n "$attempt_path" && -n "${LEGION_TELEMETRY_DIR:-}" ]] || return 1
  mkdir -p -- "$LEGION_TELEMETRY_DIR" || return 1
  python3 - "$attempt_path" "$LEGION_TELEMETRY_DIR" <<'PY'
import datetime
import json
import os
import re
import stat
import sys

attempt_path, telemetry_dir = sys.argv[1:]
intent_path = attempt_path + ".provider-span-intent"
telemetry_dir = os.path.realpath(telemetry_dir)
flags = os.O_RDWR | os.O_APPEND | os.O_CREAT | getattr(os, "O_NOFOLLOW", 0)

def checked_file(path, open_flags):
    fd = os.open(path, open_flags, 0o600)
    info = os.fstat(fd)
    path_info = os.stat(path, follow_symlinks=False)
    if (not stat.S_ISREG(info.st_mode) or info.st_nlink != 1 or
            (info.st_dev, info.st_ino) != (path_info.st_dev, path_info.st_ino)):
        os.close(fd)
        raise OSError("unsafe telemetry/index file")
    return fd, info

def fsync_directory(path):
    fd = os.open(path, os.O_RDONLY | getattr(os, "O_DIRECTORY", 0))
    try:
        os.fsync(fd)
    finally:
        os.close(fd)

try:
    if os.path.lexists(intent_path):
        fd, info = checked_file(intent_path, os.O_RDONLY | getattr(os, "O_NONBLOCK", 0) | getattr(os, "O_NOFOLLOW", 0))
        try:
            if info.st_size > 4096:
                raise ValueError("oversized append intent")
            intent = json.loads(os.read(fd, 4097))
        finally:
            os.close(fd)
        date = intent.get("date")
        if (not isinstance(date, str) or not re.fullmatch(r"\d{4}-\d{2}-\d{2}", date)
                or intent.get("schema") != "legion.provider-span-intent.v1"
                or intent.get("attempt_receipt") != attempt_path
                or intent.get("telemetry_path") != os.path.join(telemetry_dir, date + ".jsonl")
                or type(intent.get("device")) is not int
                or type(intent.get("inode")) is not int
                or type(intent.get("offset")) is not int or intent["offset"] < 0):
            raise ValueError("invalid append intent")
        fd, info = checked_file(intent["telemetry_path"], flags)
        try:
            # An unchanged file proves a previous publisher never appended.
            # If another record appeared, a partial/crashed append is ambiguous:
            # never authorize a second paid-attempt span on that uncertainty.
            if ((info.st_dev, info.st_ino) != (intent["device"], intent["inode"])
                    or info.st_size != intent["offset"]):
                raise ValueError("ambiguous prior provider-span append")
            if info.st_size and os.pread(fd, 1, info.st_size - 1) != b"\n":
                raise ValueError("telemetry ends in an incomplete line")
        finally:
            os.close(fd)
    else:
        date = datetime.datetime.now(datetime.timezone.utc).date().isoformat()
        telemetry_path = os.path.join(telemetry_dir, date + ".jsonl")
        fd, info = checked_file(telemetry_path, flags)
        try:
            if info.st_size and os.pread(fd, 1, info.st_size - 1) != b"\n":
                raise ValueError("telemetry ends in an incomplete line")
            intent = {"schema": "legion.provider-span-intent.v1",
                      "attempt_receipt": attempt_path, "date": date,
                      "telemetry_path": telemetry_path, "device": info.st_dev,
                      "inode": info.st_ino, "offset": info.st_size}
            os.fsync(fd)
        finally:
            os.close(fd)
        fsync_directory(telemetry_dir)
        fd = os.open(intent_path, os.O_WRONLY | os.O_CREAT | os.O_EXCL | getattr(os, "O_NOFOLLOW", 0), 0o600)
        try:
            encoded = (json.dumps(intent, separators=(",", ":")) + "\n").encode()
            os.write(fd, encoded)
            os.fsync(fd)
        finally:
            os.close(fd)
        fsync_directory(os.path.dirname(intent_path) or ".")
    print(date)
except (OSError, ValueError, TypeError, KeyError):
    raise SystemExit(1)
PY
}

legion_adapter_provider_span_is_durable() {
  local attempt_path="$1"
  [[ -n "$attempt_path" && -d "${LEGION_TELEMETRY_DIR:-}" ]] || return 1
  python3 - "$attempt_path" "$LEGION_TELEMETRY_DIR" "$(legion_adapter_contract_root)" <<'PY'
import hashlib
import importlib.util
import json
import os
import re
import stat
import sys
import tempfile

attempt_path, telemetry_dir, root = sys.argv[1:]
telemetry_dir = os.path.realpath(telemetry_dir)
ack_path = attempt_path + ".provider-span-ack"
intent_path = attempt_path + ".provider-span-intent"
limit = 1024 * 1024
broker_spec = importlib.util.spec_from_file_location(
    "legion_provider_span_schema", os.path.join(root, "legion-router/scripts/legion-handoff-broker.py"))
if broker_spec is None or broker_spec.loader is None:
    raise SystemExit(1)
broker = importlib.util.module_from_spec(broker_spec)
broker_spec.loader.exec_module(broker)
sys.path.insert(0, os.path.join(root, "legion-observability/scripts"))
from legion_receipts import validate_attempt

def open_regular(path, maximum):
    flags = os.O_RDONLY | getattr(os, "O_NONBLOCK", 0) | getattr(os, "O_NOFOLLOW", 0)
    descriptor = os.open(path, flags)
    info = os.fstat(descriptor)
    if not stat.S_ISREG(info.st_mode) or info.st_nlink != 1 or (maximum is not None and info.st_size > maximum):
        os.close(descriptor)
        raise OSError("unsafe bounded file")
    path_info = os.stat(path, follow_symlinks=False)
    if (path_info.st_dev, path_info.st_ino) != (info.st_dev, info.st_ino):
        os.close(descriptor)
        raise OSError("file identity changed")
    return descriptor, info

try:
    attempt_descriptor, attempt_info = open_regular(attempt_path, 65536)
    try:
        attempt = validate_attempt(json.loads(os.read(attempt_descriptor, 65537)))
        path_info = os.stat(attempt_path, follow_symlinks=False)
        if ((os.fstat(attempt_descriptor).st_dev, os.fstat(attempt_descriptor).st_ino)
                != (path_info.st_dev, path_info.st_ino)):
            raise OSError("attempt receipt replaced during validation")
    finally:
        os.close(attempt_descriptor)
    if attempt["attempt_kind"] != "provider":
        raise ValueError("provider span cannot acknowledge an aggregate attempt")
except (OSError, ValueError, TypeError, UnicodeDecodeError):
    raise SystemExit(1)

def matching_span(raw):
    if not raw.endswith(b"\n") or raw.count(b"\n") != 1 or len(raw) > limit:
        return False
    try:
        value = json.loads(raw)
        broker._validate_json_schema(value, broker.SPAN_SCHEMA)
    except (ValueError, UnicodeDecodeError, TypeError):
        return False
    if not isinstance(value, dict):
        return False
    artifacts = value.get("artifacts")
    return (value.get("schema") == "legion.span.v1"
            and value.get("run_id") == attempt["run_id"]
            and value.get("executor") == attempt["executor"]
            and value.get("duration_ms") == attempt["duration_ms"]
            and value.get("usage_status") == attempt["usage_status"]
            and value.get("tokens") == attempt["usage"]
            and value.get("cost_status") == attempt["cost_status"]
            and value.get("cost_usd") == attempt["cost_usd"]
            and (attempt["effective_model"] is None or
                 value.get("model") == attempt["effective_model"])
            and (value.get("attempt_id") is None or
                 value["attempt_id"] == attempt["attempt_id"])
            and (value.get("attempt_ordinal") is None or
                 value["attempt_ordinal"] == attempt["ordinal"])
            and isinstance(artifacts, dict)
            and artifacts.get("provider_attempt") is True
            and artifacts.get("rollup_only") is not True
            and artifacts.get("attempt_receipt") == attempt_path)

def read_intent():
    if not os.path.lexists(intent_path):
        return None
    descriptor, info = open_regular(intent_path, 4096)
    try:
        value = json.loads(os.read(descriptor, 4097))
    finally:
        os.close(descriptor)
    if not isinstance(value, dict):
        raise ValueError("invalid append intent")
    date = value.get("date")
    if (value.get("schema") != "legion.provider-span-intent.v1"
            or value.get("attempt_receipt") != attempt_path
            or not isinstance(date, str) or not re.fullmatch(r"\d{4}-\d{2}-\d{2}", date)
            or value.get("telemetry_path") != os.path.join(telemetry_dir, date + ".jsonl")
            or type(value.get("device")) is not int or type(value.get("inode")) is not int
            or type(value.get("offset")) is not int or value["offset"] < 0):
        raise ValueError("invalid append intent")
    return value

try:
    intent = read_intent()
except (OSError, ValueError, TypeError, UnicodeDecodeError):
    raise SystemExit(1)

def validate_ack():
    descriptor, info = open_regular(ack_path, 4096)
    try:
        raw = os.read(descriptor, 4097)
    finally:
        os.close(descriptor)
    value = json.loads(raw)
    if (not isinstance(value, dict) or set(value) != {
            "schema", "attempt_receipt", "telemetry_path", "device", "inode",
            "offset", "length", "span_sha256"} or
            value["schema"] != "legion.provider-span-ack.v1" or
            value["attempt_receipt"] != attempt_path or
            type(value["device"]) is not int or type(value["inode"]) is not int or
            type(value["offset"]) is not int or value["offset"] < 0 or
            type(value["length"]) is not int or not 1 <= value["length"] <= limit or
            not isinstance(value["span_sha256"], str)
            or not re.fullmatch(r"[0-9a-f]{64}", value["span_sha256"])):
        return False
    telemetry_path = value.get("telemetry_path")
    if (not isinstance(telemetry_path, str)
            or os.path.dirname(telemetry_path) != telemetry_dir
            or not re.fullmatch(r"\d{4}-\d{2}-\d{2}\.jsonl", os.path.basename(telemetry_path))
            or (intent is not None and telemetry_path != intent["telemetry_path"])):
        return False
    descriptor, current = open_regular(telemetry_path, None)
    try:
        if ((current.st_dev, current.st_ino) != (value["device"], value["inode"])):
            return False
        raw_span = os.pread(descriptor, value["length"], value["offset"])
        path_info = os.stat(telemetry_path, follow_symlinks=False)
        if ((os.fstat(descriptor).st_dev, os.fstat(descriptor).st_ino)
                != (path_info.st_dev, path_info.st_ino)):
            return False
    finally:
        os.close(descriptor)
    return (len(raw_span) == value["length"]
            and hashlib.sha256(raw_span).hexdigest() == value["span_sha256"]
            and matching_span(raw_span))

try:
    if validate_ack():
        raise SystemExit(0)
except (OSError, ValueError, TypeError, UnicodeDecodeError):
    pass

# New publications persist an attempt-specific append intent *before* emitting.
# Recover from that byte offset, not the last MiB of a possibly much larger
# file; an ambiguous unmatched append never authorizes a duplicate. Legacy
# receipts without an intent retain the bounded date-derived tail fallback.
try:
    ended_at = attempt.get("ended_at")
    if not isinstance(ended_at, str) or len(ended_at) < 10:
        raise ValueError("attempt has no date")
    telemetry_path = (intent["telemetry_path"] if intent is not None else
                      os.path.join(telemetry_dir, ended_at[:10] + ".jsonl"))
    flags = os.O_RDONLY | getattr(os, "O_NONBLOCK", 0) | getattr(os, "O_NOFOLLOW", 0)
    descriptor = os.open(telemetry_path, flags)
    try:
        info = os.fstat(descriptor)
        if not stat.S_ISREG(info.st_mode) or info.st_nlink != 1:
            raise OSError("unsafe telemetry file")
        path_info = os.stat(telemetry_path, follow_symlinks=False)
        if (info.st_dev, info.st_ino) != (path_info.st_dev, path_info.st_ino):
            raise OSError("telemetry file changed")
        if intent is not None:
            if ((info.st_dev, info.st_ino) != (intent["device"], intent["inode"]) or
                    info.st_size < intent["offset"]):
                raise OSError("append intent lost its telemetry file")
            start = intent["offset"]
        else:
            start = max(0, info.st_size - limit)
        raw = os.pread(descriptor, min(limit, info.st_size - start), start)
        # A successful acknowledgement means the JSONL bytes, not merely the
        # sidecar, survived a host crash. The acknowledgement directory follows.
        os.fsync(descriptor)
        path_info = os.stat(telemetry_path, follow_symlinks=False)
        if (os.fstat(descriptor).st_dev, os.fstat(descriptor).st_ino) != (path_info.st_dev, path_info.st_ino):
            raise OSError("telemetry file replaced during recovery")
    finally:
        os.close(descriptor)
    cursor = start
    # A fresh intent points at a known append boundary, unlike a legacy tail
    # read that may start halfway through a line. Preserve its first record.
    if start and intent is None:
        first_newline = raw.find(b"\n")
        if first_newline < 0:
            raise ValueError("no complete bounded telemetry record")
        cursor += first_newline + 1
        raw = raw[first_newline + 1:]
    found = None
    for line in raw.splitlines(keepends=True):
        if matching_span(line):
            found = (cursor, line)
        cursor += len(line)
    if found is None:
        raise ValueError("provider span not found in bounded tail")
    offset, line = found
    payload = {
        "schema": "legion.provider-span-ack.v1",
        "attempt_receipt": attempt_path,
        "telemetry_path": telemetry_path,
        "device": info.st_dev,
        "inode": info.st_ino,
        "offset": offset,
        "length": len(line),
        "span_sha256": hashlib.sha256(line).hexdigest(),
    }
    directory = os.path.dirname(ack_path)
    fd, temporary = tempfile.mkstemp(prefix=".provider-span-ack.", dir=directory)
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as destination:
            json.dump(payload, destination, separators=(",", ":"))
            destination.write("\n")
            destination.flush()
            os.fsync(destination.fileno())
        os.chmod(temporary, 0o600)
        os.replace(temporary, ack_path)
        directory_fd = os.open(directory or ".", os.O_RDONLY | getattr(os, "O_DIRECTORY", 0))
        try:
            os.fsync(directory_fd)
        finally:
            os.close(directory_fd)
        path_info = os.stat(telemetry_path, follow_symlinks=False)
        if (path_info.st_dev, path_info.st_ino) != (info.st_dev, info.st_ino):
            raise OSError("telemetry file replaced before acknowledgement")
    finally:
        try:
            os.unlink(temporary)
        except FileNotFoundError:
            pass
except (OSError, ValueError, TypeError, UnicodeDecodeError):
    raise SystemExit(1)
raise SystemExit(0)
PY
}

legion_adapter_claim_provider_span() {
  local attempt_path="$1" claim_path owner_path lock_path outcome
  [[ -n "$attempt_path" ]] || return 1
  claim_path="$attempt_path.provider-span-emitted"
  owner_path="$claim_path/owner.json"
  lock_path="$claim_path/owner.lock"
  [[ ! -L "$claim_path" ]] || return 1
  mkdir -p "$claim_path" 2>/dev/null || return 1
  outcome="$(python3 - "$lock_path" "$owner_path" "$$" \
    "${LEGION_ADAPTER_PROVIDER_SPAN_CLAIM_TOKEN:-}" <<'PY'
import ctypes
import fcntl
import json
import os
import re
import secrets
import stat
import sys
import tempfile

lock_path, owner_path, publisher_pid_text, current_claim_token = sys.argv[1:]
publisher_pid = int(publisher_pid_text)

def process_snapshot(pid):
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        return False, None, None
    except PermissionError:
        pass
    if sys.platform.startswith("linux"):
        try:
            with open("/proc/sys/kernel/random/boot_id", encoding="ascii") as source:
                boot = source.read(80).strip()
            with open(f"/proc/{pid}/stat", encoding="utf-8") as source:
                fields = source.read(4096).rsplit(")", 1)[1].split()
            start_ticks = int(fields[19])
            with open("/proc/stat", encoding="ascii") as source:
                boot_epoch = next(int(line.split()[1]) for line in source if line.startswith("btime "))
            start_epoch = boot_epoch + start_ticks / os.sysconf("SC_CLK_TCK")
            if not re.fullmatch(r"[0-9a-f-]{32,64}", boot) or start_ticks < 1:
                raise ValueError("invalid Linux process identity")
            return True, f"linux:{boot}:{start_ticks}", start_epoch
        except (OSError, IndexError, StopIteration, ValueError):
            return True, None, None
    if sys.platform == "darwin":
        class DarwinUniqueInfo(ctypes.Structure):
            _fields_ = (
                ("p_uuid", ctypes.c_uint8 * 16),
                ("p_uniqueid", ctypes.c_uint64),
                ("p_puniqueid", ctypes.c_uint64),
                ("p_idversion", ctypes.c_int32),
                ("p_orig_ppidversion", ctypes.c_int32),
                ("p_reserve2", ctypes.c_uint64),
                ("p_reserve3", ctypes.c_uint64),
            )
        try:
            libproc = ctypes.CDLL("/usr/lib/libproc.dylib")
            function = libproc.proc_pidinfo
            function.argtypes = (ctypes.c_int, ctypes.c_int, ctypes.c_uint64, ctypes.c_void_p, ctypes.c_int)
            function.restype = ctypes.c_int
            info = DarwinUniqueInfo()
            found = function(pid, 17, 0, ctypes.byref(info), ctypes.sizeof(info))
            if found == 0:
                # kill(0) already proved a live or permission-hidden process.
                # proc_pidinfo denial is not proof of death.
                return True, None, None
            if found != ctypes.sizeof(info) or info.p_uniqueid == 0:
                return True, None, None
            return True, f"darwin:{info.p_uniqueid}:{info.p_idversion}", None
        except (AttributeError, OSError):
            return True, None, None
    return True, None, None

def current_publisher_incarnation(pid):
    # Prefer the kernel identity so every publisher compares the same identity
    # kind. A supervisor token is a restricted-sandbox fallback only.
    alive, incarnation, _ = process_snapshot(pid)
    if alive and incarnation:
        return incarnation
    supervisor_token = os.environ.get("LEGION_SUPERVISOR_TOKEN", "")
    if re.fullmatch(r"[0-9a-f]{48}", supervisor_token):
        return f"supervisor:{supervisor_token}:pid:{pid}"
    return None

def valid_incarnation(value, pid):
    return bool(
        isinstance(value, str)
        and (
            re.fullmatch(r"linux:[0-9a-f-]{32,64}:[1-9][0-9]*", value)
            or re.fullmatch(r"darwin:[1-9][0-9]*:-?[0-9]+", value)
            or re.fullmatch(rf"supervisor:[0-9a-f]{{48}}:pid:{pid}", value)
        )
    )

def valid_token(value):
    return isinstance(value, str) and re.fullmatch(r"[0-9a-f]{48}", value) is not None

def read_bounded_regular(path, limit=4096):
    flags = os.O_RDONLY
    if hasattr(os, "O_NOFOLLOW"):
        flags |= os.O_NOFOLLOW
    if hasattr(os, "O_NONBLOCK"):
        flags |= os.O_NONBLOCK
    descriptor = os.open(path, flags)
    try:
        opened = os.fstat(descriptor)
        if (
            not stat.S_ISREG(opened.st_mode)
            or opened.st_nlink != 1
            or opened.st_size > limit
        ):
            raise OSError("owner is not a bounded singly-linked regular file")
        path_stat = os.stat(path, follow_symlinks=False)
        if (path_stat.st_dev, path_stat.st_ino) != (opened.st_dev, opened.st_ino):
            raise OSError("owner path changed while opening")
        chunks = []
        total = 0
        while total <= limit:
            chunk = os.read(descriptor, min(4096, limit + 1 - total))
            if not chunk:
                break
            chunks.append(chunk)
            total += len(chunk)
        raw = b"".join(chunks)
        if len(raw) > limit:
            raise OSError("owner exceeds size limit")
        closed = os.fstat(descriptor)
        path_stat = os.stat(path, follow_symlinks=False)
        if (
            not stat.S_ISREG(closed.st_mode)
            or closed.st_nlink != 1
            or closed.st_size > limit
            or (closed.st_dev, closed.st_ino) != (opened.st_dev, opened.st_ino)
            or (path_stat.st_dev, path_stat.st_ino) != (opened.st_dev, opened.st_ino)
            or closed.st_mtime_ns != opened.st_mtime_ns
            or closed.st_ctime_ns != opened.st_ctime_ns
        ):
            raise OSError("owner changed while reading")
        return raw.decode("utf-8"), opened.st_mtime
    finally:
        os.close(descriptor)

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
        owner_text, owner_mtime = read_bounded_regular(owner_path)
        candidate = json.loads(owner_text)
        if (
            isinstance(candidate, dict)
            and candidate.get("schema") == "legion.provider-span-claim.v1"
            and isinstance(candidate.get("publisher_pid"), int)
            and candidate["publisher_pid"] > 0
            and valid_incarnation(candidate.get("publisher_incarnation"), candidate["publisher_pid"])
            and valid_token(candidate.get("token"))
            and set(candidate) == {"schema", "publisher_pid", "publisher_incarnation", "token"}
        ):
            owner = candidate
        elif (
            isinstance(candidate, dict)
            and candidate.get("schema") == "legion.provider-span-claim.v1"
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
        if (
            owner["publisher_pid"] == publisher_pid
            and owner["publisher_incarnation"] == publisher_incarnation
            and valid_token(current_claim_token)
            and owner["token"] == current_claim_token
        ):
            print(f"reused:{current_claim_token}")
            raise SystemExit(0)
        owner_alive, owner_incarnation, _ = process_snapshot(owner["publisher_pid"])
        if owner_alive:
            stored_kind = owner["publisher_incarnation"].split(":", 1)[0]
            observed_kind = owner_incarnation.split(":", 1)[0] if owner_incarnation else None
            if owner_incarnation is None or stored_kind != observed_kind \
                    or owner_incarnation == owner["publisher_incarnation"]:
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
    reused:*) LEGION_ADAPTER_PROVIDER_SPAN_CLAIM_TOKEN="${outcome#reused:}"; return 0 ;;
    *) return 1 ;;
  esac
}

legion_adapter_release_provider_span_claim() {
  local attempt_path="$1" token="${LEGION_ADAPTER_PROVIDER_SPAN_CLAIM_TOKEN:-}"
  local claim_path="$attempt_path.provider-span-emitted"
  [[ -n "$attempt_path" && -n "$token" && -d "$claim_path" && ! -L "$claim_path" ]] || return 0
  python3 - "$claim_path/owner.lock" "$claim_path/owner.json" "$token" "$$" <<'PY'
import ctypes
import fcntl
import json
import os
import re
import stat
import sys

lock_path, owner_path, token, publisher_pid_text = sys.argv[1:]
publisher_pid = int(publisher_pid_text)

def process_incarnation(pid):
    if sys.platform.startswith("linux"):
        try:
            with open("/proc/sys/kernel/random/boot_id", encoding="ascii") as source:
                boot = source.read(80).strip()
            with open(f"/proc/{pid}/stat", encoding="utf-8") as source:
                fields = source.read(4096).rsplit(")", 1)[1].split()
            start_ticks = int(fields[19])
            if re.fullmatch(r"[0-9a-f-]{32,64}", boot) and start_ticks > 0:
                return f"linux:{boot}:{start_ticks}"
        except (OSError, IndexError, ValueError):
            pass
    elif sys.platform == "darwin":
        class DarwinUniqueInfo(ctypes.Structure):
            _fields_ = (
                ("p_uuid", ctypes.c_uint8 * 16),
                ("p_uniqueid", ctypes.c_uint64),
                ("p_puniqueid", ctypes.c_uint64),
                ("p_idversion", ctypes.c_int32),
                ("p_orig_ppidversion", ctypes.c_int32),
                ("p_reserve2", ctypes.c_uint64),
                ("p_reserve3", ctypes.c_uint64),
            )
        try:
            libproc = ctypes.CDLL("/usr/lib/libproc.dylib")
            function = libproc.proc_pidinfo
            function.argtypes = (ctypes.c_int, ctypes.c_int, ctypes.c_uint64, ctypes.c_void_p, ctypes.c_int)
            function.restype = ctypes.c_int
            info = DarwinUniqueInfo()
            found = function(pid, 17, 0, ctypes.byref(info), ctypes.sizeof(info))
            if found == ctypes.sizeof(info) and info.p_uniqueid:
                return f"darwin:{info.p_uniqueid}:{info.p_idversion}"
        except (AttributeError, OSError):
            pass
    supervisor_token = os.environ.get("LEGION_SUPERVISOR_TOKEN", "")
    if re.fullmatch(r"[0-9a-f]{48}", supervisor_token):
        return f"supervisor:{supervisor_token}:pid:{pid}"
    return None

def read_bounded_regular(path, limit=4096):
    flags = os.O_RDONLY
    if hasattr(os, "O_NOFOLLOW"):
        flags |= os.O_NOFOLLOW
    if hasattr(os, "O_NONBLOCK"):
        flags |= os.O_NONBLOCK
    descriptor = os.open(path, flags)
    try:
        opened = os.fstat(descriptor)
        if (
            not stat.S_ISREG(opened.st_mode)
            or opened.st_nlink != 1
            or opened.st_size > limit
        ):
            raise OSError("owner is not a bounded singly-linked regular file")
        path_stat = os.stat(path, follow_symlinks=False)
        if (path_stat.st_dev, path_stat.st_ino) != (opened.st_dev, opened.st_ino):
            raise OSError("owner path changed while opening")
        chunks = []
        total = 0
        while total <= limit:
            chunk = os.read(descriptor, min(4096, limit + 1 - total))
            if not chunk:
                break
            chunks.append(chunk)
            total += len(chunk)
        raw = b"".join(chunks)
        if len(raw) > limit:
            raise OSError("owner exceeds size limit")
        closed = os.fstat(descriptor)
        path_stat = os.stat(path, follow_symlinks=False)
        if (
            not stat.S_ISREG(closed.st_mode)
            or closed.st_nlink != 1
            or closed.st_size > limit
            or (closed.st_dev, closed.st_ino) != (opened.st_dev, opened.st_ino)
            or (path_stat.st_dev, path_stat.st_ino) != (opened.st_dev, opened.st_ino)
            or closed.st_mtime_ns != opened.st_mtime_ns
            or closed.st_ctime_ns != opened.st_ctime_ns
        ):
            raise OSError("owner changed while reading")
        return raw.decode("utf-8")
    finally:
        os.close(descriptor)

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
        owner = json.loads(read_bounded_regular(owner_path))
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
  local attempt_path="$1" pinned_date
  shift
  if [[ "${LEGION_TEST_PROVIDER_SPAN_FAULTS:-0}" == 1 \
      && "${LEGION_TEST_PROVIDER_SPAN_FAULT_STAGE:-}" == claim ]]; then
    return 1
  fi
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
  if [[ "${LEGION_TEST_PROVIDER_SPAN_FAULTS:-0}" == 1 \
      && "${LEGION_TEST_PROVIDER_SPAN_FAULT_STAGE:-}" == append ]]; then
    legion_adapter_release_provider_span_claim "$attempt_path"
    return 1
  fi
  if ! pinned_date="$(legion_adapter_prepare_provider_span "$attempt_path")"; then
    legion_adapter_release_provider_span_claim "$attempt_path"
    return 1
  fi
  LEGION_ADAPTER_SPAN_DATE="$pinned_date" emit_span "$@" || true
  # Simulate losing the acknowledgement after the append. The durable span is
  # deliberately retained so a retry proves exact-once reconciliation.
  if [[ "${LEGION_TEST_PROVIDER_SPAN_FAULTS:-0}" == 1 \
      && "${LEGION_TEST_PROVIDER_SPAN_FAULT_STAGE:-}" == commit ]]; then
    legion_adapter_release_provider_span_claim "$attempt_path"
    return 1
  fi
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
  local task_text="${1:-}" lease_path="${2:-}" attempt_path root trace_bin pinned_date
  local executor model terminal span_status duration usage cost usage_status cost_status artifacts
  [[ "$LEGION_ADAPTER_SIGNAL_TERMINALIZED" == 1 ]] || return 0
  attempt_path="$LEGION_ADAPTER_SIGNAL_ART/attempt-$LEGION_ADAPTER_SIGNAL_ORDINAL.json"
  [[ -f "$attempt_path" ]] || return 0
  if [[ "${LEGION_TEST_PROVIDER_SPAN_FAULTS:-0}" == 1 \
      && "${LEGION_TEST_PROVIDER_SPAN_FAULT_STAGE:-}" == claim ]]; then
    return 1
  fi
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
  if [[ "${LEGION_TEST_PROVIDER_SPAN_FAULTS:-0}" == 1 \
      && "${LEGION_TEST_PROVIDER_SPAN_FAULT_STAGE:-}" == append ]]; then
    legion_adapter_release_provider_span_claim "$attempt_path"
    return 1
  fi
  if ! pinned_date="$(legion_adapter_prepare_provider_span "$attempt_path")"; then
    legion_adapter_release_provider_span_claim "$attempt_path"
    return 1
  fi
  if [[ ! -x "$trace_bin" ]] || ! LEGION_ADAPTER_SPAN_DATE="$pinned_date" "$trace_bin" emit \
      --executor "$executor" --model "$model" --status "$span_status" \
      --run-id "$RUN_ID" --trace-id "${LEGION_TRACE_ID:-$RUN_ID}" \
      --parent-id "${LEGION_PARENT_ID:-}" --archetype "${archetype:-${ARCHETYPE:-}}" \
      --duration-ms "$duration" --cost "$cost" --cost-status "$cost_status" \
      --task "$task_text" --tokens "$usage" --usage-status "$usage_status" \
      --artifacts "$artifacts" >/dev/null 2>&1; then
    legion_adapter_release_provider_span_claim "$attempt_path"
    return 1
  fi
  if [[ "${LEGION_TEST_PROVIDER_SPAN_FAULTS:-0}" == 1 \
      && "${LEGION_TEST_PROVIDER_SPAN_FAULT_STAGE:-}" == commit ]]; then
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
