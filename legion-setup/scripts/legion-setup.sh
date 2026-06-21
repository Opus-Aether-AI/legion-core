#!/usr/bin/env bash
# legion-setup — one command to install OR update Legion. Auto-detects which.
#
#   legion-setup            # install if absent, update if present (idempotent)
#   legion-setup install [profile]   # all (default) | opus | vendored | minimal | <plugin>
#   legion-setup update     # pull latest + re-sync
#   legion-setup status     # what's installed
#   legion-setup codex [all|mcp|skills|verify]  # wire Legion into Codex CLI
#   legion-setup cursor [all|mcp|agents|verify] # wire Legion into Cursor Agent
#   legion-setup uninstall [flags]
#
# First-time bootstrap (before this script exists on the machine) — one paste:
#   gh api repos/your-org/legion-core/contents/scripts/install.sh --jq '.content' | base64 -d | bash -s all
set -euo pipefail

HERE="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
REPO="${LEGION_REPO:-your-org/legion-core}"
SLUG="${LEGION_SLUG:-legion}"
AGENTS_HOME="${AGENTS_HOME:-$HOME/.agents}"
SOURCE_CLONE="$AGENTS_HOME/sources/$SLUG"
PROFILE="${LEGION_PROFILE:-all}"

green()  { printf '\033[0;32m%s\033[0m\n' "$*"; }
yellow() { printf '\033[0;33m%s\033[0m\n' "$*"; }
red()    { printf '\033[0;31m%s\033[0m\n' "$*" >&2; }

is_installed() { [[ -d "$SOURCE_CLONE/.git" ]]; }

do_install() {
  local profile="${1:-$PROFILE}"
  command -v gh >/dev/null 2>&1 || { red "gh CLI required (https://cli.github.com), then: gh auth login"; exit 1; }
  green "Installing Legion ($REPO, profile=$profile) …"
  gh api "repos/$REPO/contents/scripts/install.sh" --jq '.content' | base64 -d | bash -s "$profile"
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
    claude plugin marketplace list 2>/dev/null | grep -i "$SLUG" && green "marketplace registered" || yellow "marketplace not registered with claude"
  fi
}

case "${1:-auto}" in
  install)        shift || true; do_install "${1:-$PROFILE}" ;;
  update|refresh) do_update ;;
  status)         cmd_status ;;
  codex)          shift || true; exec "$HERE/legion-codex-setup.sh" "$@" ;;
  cursor)         shift || true; exec "$HERE/legion-cursor-setup.sh" "$@" ;;
  uninstall)
    if is_installed; then bash "$SOURCE_CLONE/scripts/uninstall.sh" "${@:2}"; else yellow "not installed"; fi ;;
  auto|"")        if is_installed; then do_update; else do_install; fi ;;
  -h|--help)      sed -n '2,16p' "$0" ;;
  *)              red "usage: legion-setup [install [profile]|update|status|codex|cursor|uninstall|auto]"; exit 2 ;;
esac
