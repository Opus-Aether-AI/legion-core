#!/usr/bin/env bash
set -euo pipefail

# ── Legion Router — CLI / launchd manager ────────────────────────────
# Manages the router.ts metering proxy (loopback :8082) as a launchd service on
# macOS, or as a foreground process everywhere else. Keys are OPTIONAL — the
# router runs as a pure meter without them.
#
#   legion-router install     # store keys + set up launchd on macOS
#   legion-router uninstall   # remove plist + stop
#   legion-router start|stop|restart|status|logs|errors
#   legion-router dev         # run in foreground (debug)
#
# Service management (install/uninstall/start/stop/restart/status) uses launchd
# and is macOS-only. On Linux use `legion-router dev` (or wrap
# scripts/router-wrapper.sh in a systemd unit); `install` still stores
# credentials portably, and `logs`/`errors`/`dev` are portable.

PLUGIN_DIR="$(cd "$(dirname "$0")/.." && pwd)"
WRAPPER_PATH="$PLUGIN_DIR/scripts/router-wrapper.sh"
# Harness-neutral global log root (back-compat: an existing ~/.claude/logs/legion
# is kept, so this is a no-op on established Claude installs).
_legion_state_py="$PLUGIN_DIR/../legion-observability/scripts/legion_state.py"
LOG_DIR="${LEGION_LOG_DIR:-$(python3 "$_legion_state_py" --log-root 2>/dev/null || echo "$HOME/.claude/logs/legion")}"
LOG_FILE="$LOG_DIR/router.log"
ERR_FILE="$LOG_DIR/router.err.log"

PLIST_LABEL="com.legion-core.router"
PLIST_PATH="$HOME/Library/LaunchAgents/$PLIST_LABEL.plist"

BUN_PATH="${BUN_PATH:-$(command -v bun 2>/dev/null || echo "$HOME/.bun/bin/bun")}"
ROUTER_PORT="${ROUTER_PORT:-8082}"
# shellcheck disable=SC1091
source "$PLUGIN_DIR/scripts/lib/router-secrets.sh"

red()    { printf '\033[0;31m%s\033[0m\n' "$*"; }
green()  { printf '\033[0;32m%s\033[0m\n' "$*"; }
yellow() { printf '\033[0;33m%s\033[0m\n' "$*"; }
dim()    { printf '\033[0;90m%s\033[0m\n' "$*"; }

# Service management goes through launchd, so uninstall/start/stop/restart/status
# are macOS-only. `install` stores credentials everywhere, then installs launchd
# only when available. Fail fast with a clear pointer instead of dying mid-script
# on `launchctl: command not found`.
require_launchd() {  # $1 = subcommand, for the message
  if [[ "$(uname -s)" != "Darwin" ]] || ! command -v launchctl >/dev/null 2>&1; then
    red "legion-router $1 manages a launchd service and is macOS-only."
    yellow "On Linux, run the router in the foreground:  legion-router dev"
    yellow "or wrap scripts/router-wrapper.sh in a systemd unit / your process supervisor."
    exit 1
  fi
}

check_installed() {
  [[ -f "$PLIST_PATH" ]] || { red "Not installed. Run: legion-router install"; exit 1; }
}

store_secret_if_present() {
  local name="${1:?secret name required}" value="${2:-}" label="${3:?label required}" missing="${4:?missing message required}"
  local backend="" path=""
  if [[ -z "$value" ]]; then
    yellow "$missing"
    return 0
  fi
  if backend="$(legion_router_store_secret "$name" "$value")"; then
    case "$backend" in
      keychain) green "$label stored in Keychain ($(legion_router_secret_service "$name"))" ;;
      libsecret) green "$label stored via secret-tool/libsecret ($(legion_router_secret_service "$name"))" ;;
      file)
        path="$(legion_router_secret_file_path "$name")"
        green "$label stored in $path"
        ;;
    esac
  else
    yellow "Could not persist $label; set $(legion_router_secret_env "$name") in the environment when starting the router."
  fi
}

cmd_install() {
  mkdir -p "$LOG_DIR"
  local cli_api_key="" cli_token=""
  shift || true
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --api-key) cli_api_key="${2:-}"; shift 2 ;;
      --token)   cli_token="${2:-}"; shift 2 ;;
      *) shift ;;
    esac
  done

  echo "Legion Router — install"
  echo "━━━━━━━━━━━━━━━━━━━━━━━"

  # Keys are optional. Store whatever we can find; the router meters either way.
  local anthropic_key="${cli_api_key:-${ANTHROPIC_API_KEY:-}}"
  local minimax_token="${cli_token:-${MINIMAX_AUTH_TOKEN:-}}"

  store_secret_if_present anthropic "$anthropic_key" "Anthropic key" \
    "No Anthropic key — running as a meter; claude-* will pass through client auth."
  store_secret_if_present minimax "$minimax_token" "MiniMax token" \
    "No MiniMax token — minimax-* models fall back to Anthropic."

  local model_map="${MINIMAX_MODEL_MAP:-}"
  # model_map is interpolated raw into the plist XML — reject anything outside a
  # safe charset so a stray < / & / quote can't malform or inject plist keys.
  if [[ -n "$model_map" && ! "$model_map" =~ ^[A-Za-z0-9.,:_/-]+$ ]]; then
    yellow "Ignoring MINIMAX_MODEL_MAP (unsafe characters): $model_map"
    model_map=""
  fi

  if [[ "$(uname -s)" != "Darwin" ]] || ! command -v launchctl >/dev/null 2>&1; then
    yellow "launchd is unavailable here, so install only stored credentials."
    yellow "Run the router with: legion-router dev"
    yellow "or wrap scripts/router-wrapper.sh in your process supervisor."
    return 0
  fi

  if launchctl list "$PLIST_LABEL" >/dev/null 2>&1; then
    launchctl unload "$PLIST_PATH" 2>/dev/null || true
  fi

  cat > "$PLIST_PATH" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>$PLIST_LABEL</string>
    <key>ProgramArguments</key>
    <array>
        <string>/bin/bash</string>
        <string>$WRAPPER_PATH</string>
    </array>
    <key>WorkingDirectory</key>
    <string>$HOME</string>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <true/>
    <key>StandardOutPath</key>
    <string>$LOG_FILE</string>
    <key>StandardErrorPath</key>
    <string>$ERR_FILE</string>
    <key>EnvironmentVariables</key>
    <dict>
        <key>HOME</key>
        <string>$HOME</string>
        <key>PATH</key>
        <string>$(dirname "$BUN_PATH"):/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin</string>
        <key>ROUTER_PORT</key>
        <string>$ROUTER_PORT</string>
        <key>MINIMAX_MODEL_MAP</key>
        <string>$model_map</string>
    </dict>
</dict>
</plist>
PLIST

  chmod 600 "$PLIST_PATH"
  launchctl load "$PLIST_PATH"

  if curl -sf --retry 10 --retry-connrefused --retry-delay 1 -m 2 "http://127.0.0.1:$ROUTER_PORT/health" >/dev/null 2>&1; then
    green "Installed and running on 127.0.0.1:$ROUTER_PORT"
    echo ""; cmd_status
  else
    yellow "Plist loaded but proxy not responding yet. Check: legion-router errors"
  fi
}

cmd_uninstall() {
  if [[ -f "$PLIST_PATH" ]]; then
    launchctl unload "$PLIST_PATH" 2>/dev/null || true
    rm -f "$PLIST_PATH"
    green "Uninstalled."
  else
    yellow "Not installed."
  fi
}

cmd_start()   { check_installed; launchctl load "$PLIST_PATH" 2>/dev/null || true; cmd_status; }
cmd_stop()    { check_installed; launchctl unload "$PLIST_PATH" 2>/dev/null || true; green "Stopped."; }
cmd_restart() { check_installed; launchctl unload "$PLIST_PATH" 2>/dev/null || true; launchctl load "$PLIST_PATH"; cmd_status; }

cmd_status() {
  echo "Legion Router — status"
  echo "━━━━━━━━━━━━━━━━━━━━━━"
  if launchctl list "$PLIST_LABEL" >/dev/null 2>&1; then
    green "launchd: loaded"
  else
    red "launchd: not loaded"
  fi
  local health
  if health=$(curl -sf -m 2 "http://127.0.0.1:$ROUTER_PORT/health" 2>/dev/null); then
    dim "  health:  $(printf '%s' "$health" | jq -r '.status' 2>/dev/null || echo '?')"
    dim "  anthropic key: $(printf '%s' "$health" | jq -r '.anthropicKeySet' 2>/dev/null || echo '?')"
    dim "  minimax token: $(printf '%s' "$health" | jq -r '.minimaxTokenSet' 2>/dev/null || echo '?')"
  else
    red "  health:  not responding on 127.0.0.1:$ROUTER_PORT"
  fi
}

cmd_logs() {
  if [[ -f "$LOG_FILE" ]]; then
    tail -f "$LOG_FILE"
  else
    yellow "No log yet: $LOG_FILE"
  fi
}

cmd_errors() {
  if [[ -f "$ERR_FILE" ]]; then
    tail -f "$ERR_FILE"
  else
    yellow "No error log yet: $ERR_FILE"
  fi
}
cmd_dev()    { echo "Running in foreground (Ctrl+C to stop)..."; exec /bin/bash "$WRAPPER_PATH"; }

# Service-management commands need launchd → macOS-only. dev/logs/errors are
# portable, and install stores credentials everywhere before the launchd step.
case "${1:-}" in uninstall|start|stop|restart|status) require_launchd "$1" ;; esac

case "${1:-}" in
  install)   cmd_install "$@" ;;
  uninstall) cmd_uninstall ;;
  start)     cmd_start ;;
  stop)      cmd_stop ;;
  restart)   cmd_restart ;;
  status)    cmd_status ;;
  logs)      cmd_logs ;;
  errors)    cmd_errors ;;
  dev)       cmd_dev ;;
  *)
    echo "Usage: legion-router {install [--api-key KEY] [--token TOKEN]|uninstall|start|stop|restart|status|logs|errors|dev}"
    exit 1
    ;;
esac
