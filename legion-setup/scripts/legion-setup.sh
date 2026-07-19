#!/usr/bin/env bash
# legion-setup — one command to install OR update Legion. Auto-detects which.
#
#   legion-setup            # install if absent, update if present (idempotent)
#   legion-setup install [profile]   # all (default) | opus | vendored | minimal | <plugin>
#   legion-setup update     # pull latest + re-sync
#   legion-setup status     # what's installed
#   legion-setup codex [all|mcp|skills|verify]  # wire Legion into Codex CLI
#   legion-setup cursor [all|mcp|agents|verify] # wire Legion into Cursor Agent
#   legion-setup opencode [all|mcp|verify]      # wire Legion into opencode
#   legion-setup uninstall [flags]
#
# First-time bootstrap (before this script exists on the machine) — one paste:
#   curl -fsSL https://raw.githubusercontent.com/Opus-Aether-AI/legion-core/main/scripts/install.sh | bash -s all
set -euo pipefail

HERE="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
REPO="${LEGION_REPO:-Opus-Aether-AI/legion-core}"
RAW_BASE="${LEGION_RAW_BASE:-https://raw.githubusercontent.com/${REPO}/main}"
SLUG="${LEGION_SLUG:-legion-core}"
AGENTS_HOME="${AGENTS_HOME:-$HOME/.agents}"
SOURCE_CLONE="$AGENTS_HOME/sources/$SLUG"
PROFILE="${LEGION_PROFILE:-all}"

green()  { printf '\033[0;32m%s\033[0m\n' "$*"; }
yellow() { printf '\033[0;33m%s\033[0m\n' "$*"; }
red()    { printf '\033[0;31m%s\033[0m\n' "$*" >&2; }

is_installed() { [[ -d "$SOURCE_CLONE/.git" ]]; }

do_install() {
  local profile="${1:-$PROFILE}"
  command -v curl >/dev/null 2>&1 || { red "curl required (https://curl.se)"; exit 1; }
  green "Installing Legion ($REPO, profile=$profile) …"
  curl -fsSL "${RAW_BASE%/}/scripts/install.sh" | bash -s "$profile"
  green "✓ Installed. Update anytime by asking Claude to 'update legion', or: legion-setup update"
}

do_update() {
  if is_installed && [[ -f "$SOURCE_CLONE/scripts/refresh.sh" ]]; then
    green "Updating Legion (refresh from $REPO) …"
    bash "$SOURCE_CLONE/scripts/refresh.sh"
    green "✓ Updated."
  else
    yellow "Legion isn't installed yet — installing instead."
    do_install
  fi
}

cmd_status() {
  if is_installed; then
    green "Legion installed: $SOURCE_CLONE"
    ( cd "$SOURCE_CLONE" && git log -1 --oneline 2>/dev/null ) || true
  else
    yellow "Legion not installed (no source clone at $SOURCE_CLONE). Run: legion-setup install"
  fi
  if command -v claude >/dev/null 2>&1; then
    if claude plugin marketplace list 2>/dev/null | grep -i "$SLUG" >/dev/null; then
      green "marketplace registered"
    else
      yellow "marketplace not registered with claude"
    fi
  fi
}

case "${1:-auto}" in
  install)        shift || true; do_install "${1:-$PROFILE}" ;;
  update|refresh) do_update ;;
  status)         cmd_status ;;
  codex)          shift || true; exec "$HERE/legion-codex-setup.sh" "$@" ;;
  cursor)         shift || true; exec "$HERE/legion-cursor-setup.sh" "$@" ;;
  opencode)       shift || true; exec "$HERE/legion-opencode-setup.sh" "$@" ;;
  uninstall)
    if is_installed; then bash "$SOURCE_CLONE/scripts/uninstall.sh" "${@:2}"; else yellow "not installed"; fi ;;
  auto|"")        if is_installed; then do_update; else do_install; fi ;;
  -h|--help)      sed -n '2,16p' "$0" ;;
  *)              red "usage: legion-setup [install [profile]|update|status|codex|cursor|opencode|uninstall|auto]"; exit 2 ;;
esac
