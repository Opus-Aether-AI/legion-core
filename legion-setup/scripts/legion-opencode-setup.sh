#!/usr/bin/env bash
# legion-opencode-setup — make Legion work natively on opencode.
#
# opencode supports headless `opencode run`, MCP via ~/.config/opencode/opencode.json,
# and passive skill discovery from ~/.agents/skills. This wires Legion's MCP servers
# into opencode and verifies readiness, without touching Codex/Claude/Cursor auth.
# (Legion's skills are read passively by opencode, so no command/agent bridge is
# needed; the legion-* delegation CLIs are already on PATH.)
#
#   legion-opencode-setup            # all: MCP + verify
#   legion-opencode-setup mcp        # register marketplace MCPs in opencode.json
#   legion-opencode-setup verify     # read-only readiness check

set -euo pipefail

HERE="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
# shellcheck disable=SC1091
source "$HERE/legion-marketplace-root.sh"
MARKETPLACE_ROOT="$(legion_resolve_marketplace_root "$HERE" "$HERE/../..")"
AGENTS_HOME="${AGENTS_HOME:-$HOME/.agents}"
AGENTS_SKILLS="$AGENTS_HOME/skills"
OPENCODE_CONFIG="${OPENCODE_CONFIG:-${XDG_CONFIG_HOME:-$HOME/.config}/opencode/opencode.json}"
MCP_MERGE_PY="$HERE/legion-opencode-mcp-merge.py"

green()  { printf '\033[0;32m%s\033[0m\n' "$*"; }
yellow() { printf '\033[0;33m%s\033[0m\n' "$*"; }
red()    { printf '\033[0;31m%s\033[0m\n' "$*" >&2; }
dim()    { printf '\033[2m%s\033[0m\n' "$*"; }

need() { command -v "$1" >/dev/null 2>&1 || { red "missing dependency: $1"; exit 1; }; }

record_setup_failure() {
  local summary="$1" evidence="${2:-}"
  local learn="${LEGION_SELF_LEARN_BIN:-$MARKETPLACE_ROOT/legion-observability/bin/legion-self-learn}"
  [[ -x "$learn" ]] || return 0
  "$learn" record --entity plugin:legion-setup --summary "$summary" \
    --severity high --source "legion-opencode-setup" --evidence "$evidence" >/dev/null 2>&1 || true
}

count_dirs() {
  [[ -d "$1" ]] || { printf '0'; return 0; }
  find "$1" -maxdepth 1 -mindepth 1 -type d 2>/dev/null | wc -l | tr -d ' '
}

opencode_bin() {
  [[ -x "$HOME/.opencode/bin/opencode" ]] && { printf '%s' "$HOME/.opencode/bin/opencode"; return 0; }
  command -v opencode 2>/dev/null || true
}

collect_mcp_servers() {
  need jq
  local acc='{}' pj plugin_dir servers
  while IFS= read -r pj; do
    jq -e 'has("mcpServers") and (.mcpServers | length > 0)' "$pj" >/dev/null 2>&1 || continue
    plugin_dir="$(cd "$(dirname "$pj")/.." >/dev/null 2>&1 && pwd)"
    servers="$(jq -c --arg root "$plugin_dir" '
      .mcpServers
      | walk(if type == "string" then gsub("\\$\\{CLAUDE_PLUGIN_ROOT\\}"; $root) else . end)
    ' "$pj")"
    acc="$(jq -c --argjson add "$servers" '. + $add' <<<"$acc")"
  done < <(find "$MARKETPLACE_ROOT" -maxdepth 3 -path '*/.claude-plugin/plugin.json' -not -path '*/vendored/*' 2>/dev/null | sort)
  printf '%s' "$acc"
}

cmd_mcp() {
  need python3
  [[ -f "$MCP_MERGE_PY" ]] || { red "merge helper not found: $MCP_MERGE_PY"; exit 1; }
  local servers count out added skipped updated
  servers="$(collect_mcp_servers)"
  count="$(jq -r 'length' <<<"$servers")"
  if [[ "$count" == "0" ]]; then
    yellow "No MCP servers declared in the marketplace at $MARKETPLACE_ROOT (nothing to register)"
    return 0
  fi
  green "Registering $count marketplace MCP server(s) into $OPENCODE_CONFIG ..."
  out="$(printf '%s' "$servers" | python3 "$MCP_MERGE_PY" --config "$OPENCODE_CONFIG" "$@")"
  if [[ "$(jq -r 'has("error")' <<<"$out")" == "true" ]]; then
    red "  $(jq -r '.error' <<<"$out")"
    record_setup_failure "opencode MCP registration failed." "$out"
    return 1
  fi
  added="$(jq -r '.added | join(", ")' <<<"$out")"
  skipped="$(jq -r '.skipped | join(", ")' <<<"$out")"
  updated="$(jq -r '.updated | join(", ")' <<<"$out")"
  [[ -n "$added"   ]] && green "  + added:   $added"
  [[ -n "$updated" ]] && green "  ~ updated: $updated"
  [[ -n "$skipped" ]] && dim   "  = already present: $skipped"
  green "opencode MCP servers in sync. Restart opencode to pick them up."
}

cmd_verify() {
  need jq
  local ok=0
  green "Legion <-> opencode readiness"

  local expected want
  expected="$(collect_mcp_servers)"
  want="$(jq -r 'keys[]' <<<"$expected" 2>/dev/null || true)"
  if [[ -n "$want" ]]; then
    if [[ -f "$OPENCODE_CONFIG" ]]; then
      while IFS= read -r name; do
        [[ -z "$name" ]] && continue
        if jq -e --arg name "$name" '.mcp[$name]' "$OPENCODE_CONFIG" >/dev/null 2>&1; then
          dim "  ok MCP $name registered"
        else
          yellow "  missing MCP $name - run: legion-opencode-setup mcp"; ok=1
        fi
      done <<<"$want"
    else
      yellow "  missing $OPENCODE_CONFIG - run: legion-opencode-setup mcp"; ok=1
    fi
  else
    dim "  ok no marketplace MCP servers to register"
  fi

  local skills
  skills="$(count_dirs "$AGENTS_SKILLS")"
  if (( skills > 0 )); then dim "  ok $skills Legion skills available to opencode via $AGENTS_SKILLS"; else yellow "  no mirrored skills at $AGENTS_SKILLS - run: legion-setup update"; ok=1; fi

  if command -v legion-delegate >/dev/null 2>&1; then dim "  ok legion-delegate on PATH (reverse-delegate to any executor)"; else yellow "  legion-delegate not on PATH - run: legion-setup install"; ok=1; fi
  if command -v legion-opencode >/dev/null 2>&1; then dim "  ok legion-opencode on PATH (delegate TO opencode)"; else yellow "  legion-opencode not on PATH - run: legion-setup install"; ok=1; fi

  local oc_bin
  oc_bin="$(opencode_bin)"
  if [[ -n "$oc_bin" ]]; then
    dim "  ok opencode CLI present ($oc_bin)"
    if [[ -f "${XDG_DATA_HOME:-$HOME/.local/share}/opencode/auth.json" ]]; then
      dim "  ok opencode auth present"
    else
      yellow "  opencode present but no auth (~/.local/share/opencode/auth.json) - run: opencode auth login"; ok=1
    fi
  else
    yellow "  opencode CLI not found (install opencode for headless delegation)"; ok=1
  fi

  if (( ok == 0 )); then
    green "Legion is wired into opencode."
  else
    yellow "Some checks failed (see above)."
    record_setup_failure "opencode setup verification failed." "Run legion-setup opencode verify for details."
  fi
  return "$ok"
}

case "${1:-all}" in
  mcp)     shift || true; cmd_mcp "$@" ;;
  verify)  cmd_verify ;;
  all|"")  cmd_mcp; echo; cmd_verify || true ;;
  -h|--help) sed -n '2,14p' "$0" ;;
  *)       red "usage: legion-opencode-setup [all|mcp|verify]"; exit 2 ;;
esac
