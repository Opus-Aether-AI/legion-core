#!/usr/bin/env bash
set -euo pipefail

# ── Legion Router — CLI / launchd manager ────────────────────────────
# Manages the router.ts metering proxy (loopback :8082) as a launchd service.
# Keys are OPTIONAL — the router runs as a pure meter without them.
#
#   legion-router install     # set up launchd (stores keys in Keychain if given)
#   legion-router uninstall   # remove plist + stop
#   legion-router start|stop|restart|status|logs|errors
#   legion-router dev         # run in foreground (debug)
#
# Service management (install/uninstall/start/stop/restart/status) uses launchd
# + the macOS Keychain and is macOS-only. On Linux use `legion-router dev` (or
# wrap scripts/router.ts in a systemd unit); `logs`/`errors`/`dev` are portable.

PLUGIN_DIR="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT_PATH="$PLUGIN_DIR/scripts/router.ts"
WRAPPER_PATH="$PLUGIN_DIR/scripts/router-wrapper.sh"
LOG_DIR="${LEGION_LOG_DIR:-$HOME/.claude/logs/legion}"
LOG_FILE="$LOG_DIR/router.log"
ERR_FILE="$LOG_DIR/router.err.log"

PLIST_LABEL="com.legion-core.router"
PLIST_PATH="$HOME/Library/LaunchAgents/$PLIST_LABEL.plist"

BUN_PATH="${BUN_PATH:-$(command -v bun 2>/dev/null || echo "$HOME/.bun/bin/bun")}"
ROUTER_PORT="${ROUTER_PORT:-8082}"

red()    { printf '\033[0;31m%s\033[0m\n' "$*"; }
green()  { printf '\033[0;32m%s\033[0m\n' "$*"; }
yellow() { printf '\033[0;33m%s\033[0m\n' "$*"; }
dim()    { printf '\033[0;90m%s\033[0m\n' "$*"; }

# Service management goes through launchd + the macOS Keychain, so install/start/
# stop/restart/status are macOS-only. `dev` (foreground bun) and `logs`/`errors`
# (tail) are portable and the documented Linux path. Fail fast with a clear
# pointer instead of dying mid-script on `launchctl: command not found`.
require_macos() {  # $1 = subcommand, for the message
  if [[ "$(uname -s)" != "Darwin" ]] || ! command -v launchctl >/dev/null 2>&1 \
       || ! command -v security >/dev/null 2>&1; then
    red "legion-router $1 manages a launchd service and is macOS-only."
    yellow "On Linux, run the router in the foreground:  legion-router dev"
    yellow "or wrap scripts/router.ts in a systemd unit / your process supervisor."
    exit 1
  fi
}

check_installed() {
  [[ -f "$PLIST_PATH" ]] || { red "Not installed. Run: legion-router install"; exit 1; }
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

  if [[ -n "$anthropic_key" ]]; then
    security delete-generic-password -s "legion-anthropic" >/dev/null 2>&1 || true
    security add-generic-password -s "legion-anthropic" -a "legion-router" -w "$anthropic_key" >/dev/null 2>&1 \
      && green "Anthropic key stored in Keychain (legion-anthropic)"
  else
    yellow "No Anthropic key — running as a meter; claude-* will pass through client auth."
  fi
  if [[ -n "$minimax_token" ]]; then
    security delete-generic-password -s "legion-minimax" >/dev/null 2>&1 || true
    security add-generic-password -s "legion-minimax" -a "legion-router" -w "$minimax_token" >/dev/null 2>&1 \
      && green "MiniMax token stored in Keychain (legion-minimax)"
  else
    yellow "No MiniMax token — minimax-* models fall back to Anthropic."
  fi

  local model_map="${MINIMAX_MODEL_MAP:-}"
  # model_map is interpolated raw into the plist XML — reject anything outside a
  # safe charset so a stray < / & / quote can't malform or inject plist keys.
  if [[ -n "$model_map" && ! "$model_map" =~ ^[A-Za-z0-9.,:_/-]+$ ]]; then
    yellow "Ignoring MINIMAX_MODEL_MAP (unsafe characters): $model_map"
    model_map=""
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

cmd_logs()   { [[ -f "$LOG_FILE" ]] && tail -f "$LOG_FILE" || yellow "No log yet: $LOG_FILE"; }
cmd_errors() { [[ -f "$ERR_FILE" ]] && tail -f "$ERR_FILE" || yellow "No error log yet: $ERR_FILE"; }
cmd_dev()    { echo "Running in foreground (Ctrl+C to stop)..."; exec "$BUN_PATH" run "$SCRIPT_PATH"; }

# Service-management commands need launchd + Keychain → macOS-only. dev/logs/
# errors are portable. Gate the launchd-bound ones up front (see require_macos).
case "${1:-}" in install|uninstall|start|stop|restart|status) require_macos "$1" ;; esac

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
