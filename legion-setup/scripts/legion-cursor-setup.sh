#!/usr/bin/env bash
# legion-cursor-setup — make Legion work natively on Cursor Agent.
#
# Cursor supports headless `agent -p`, MCP via ~/.cursor/mcp.json, AGENTS.md, and
# user subagents under ~/.cursor/agents. This script wires Legion into those
# surfaces without touching Codex/Claude auth.
#
#   legion-cursor-setup            # all: MCP + Cursor agents + verify
#   legion-cursor-setup mcp        # register marketplace MCPs in ~/.cursor/mcp.json
#   legion-cursor-setup agents     # bridge Legion agents/commands + skill loader
#   legion-cursor-setup verify     # read-only readiness check

set -euo pipefail

HERE="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
# shellcheck disable=SC1091
source "$HERE/legion-marketplace-root.sh"
# Prefer an explicit root override, else walk up to the consumer marketplace, else
# fall back to the standalone legion-core layout.
MARKETPLACE_ROOT="$(legion_resolve_marketplace_root "$HERE" "$HERE/../..")"
AGENTS_HOME="${AGENTS_HOME:-$HOME/.agents}"
AGENTS_SKILLS="$AGENTS_HOME/skills"
CURSOR_MCP_CONFIG="${CURSOR_MCP_CONFIG:-$HOME/.cursor/mcp.json}"
CURSOR_AGENTS="${CURSOR_AGENTS:-$HOME/.cursor/agents}"
MCP_MERGE_PY="$HERE/legion-cursor-mcp-merge.py"
BRIDGE_PY="$HERE/legion-cursor-bridge.py"

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
    --severity high --source "legion-cursor-setup" --evidence "$evidence" >/dev/null 2>&1 || true
}

count_dirs() {
  [[ -d "$1" ]] || { printf '0'; return 0; }
  local entry count=0
  for entry in "$1"/*; do
    [[ -d "$entry" ]] && count=$((count + 1))
  done
  printf '%s' "$count"
}

count_files() {
  [[ -d "$1" ]] || { printf '0'; return 0; }
  find "$1" -maxdepth 1 -type f -name '*.md' 2>/dev/null | wc -l | tr -d ' '
}

cursor_agent_bin() {
  command -v agent 2>/dev/null || command -v cursor-agent 2>/dev/null || true
}

plugin_manifest_paths() {
  local scope="${1:-selected}"
  local marketplace="$MARKETPLACE_ROOT/.claude-plugin/marketplace.json"
  if [[ "$scope" != "all" && -n "${LEGION_SELECTED_PLUGINS_FILE:-}" ]]; then
    [[ -f "$marketplace" ]] || {
      red "marketplace manifest not found: $marketplace"
      return 1
    }
    local source manifest plugin_dir root_real sources
    root_real="$(cd -P "$MARKETPLACE_ROOT" >/dev/null 2>&1 && pwd)" || return 1
    if ! sources="$(jq -r --rawfile selected "$LEGION_SELECTED_PLUGINS_FILE" '
      ($selected | split("\n") | map(select(length > 0))) as $names
      | .plugins[]
      | select(.name as $name | ($names | index($name)) != null)
      | select(.source | type == "string" and startswith("./") and (startswith("./vendored/") | not))
      | .source
    ' "$marketplace")"; then
      red "could not parse selected plugins from $marketplace"
      return 1
    fi
    while IFS= read -r source; do
      [[ -n "$source" ]] || continue
      plugin_dir="$(cd -P "$MARKETPLACE_ROOT/${source#./}" >/dev/null 2>&1 && pwd)" || continue
      case "$plugin_dir" in
        "$root_real"|"$root_real"/*) ;;
        *) red "selected plugin source escapes marketplace root: $source"; return 1 ;;
      esac
      manifest="$plugin_dir/.claude-plugin/plugin.json"
      [[ -f "$manifest" ]] && printf '%s\n' "$manifest"
    done <<< "$sources"
    return 0
  fi
  find "$MARKETPLACE_ROOT" -maxdepth 3 -path '*/.claude-plugin/plugin.json' \
    -not -path '*/vendored/*' 2>/dev/null | sort
}

collect_mcp_servers() {
  need jq
  local scope="${1:-selected}" acc='{}' pj plugin_dir servers manifests
  manifests="$(plugin_manifest_paths "$scope")" || return 1
  while IFS= read -r pj; do
    [[ -n "$pj" ]] || continue
    jq -e 'has("mcpServers") and (.mcpServers | length > 0)' "$pj" >/dev/null 2>&1 || continue
    plugin_dir="$(cd "$(dirname "$pj")/.." >/dev/null 2>&1 && pwd)"
    servers="$(jq -c --arg root "$plugin_dir" '
      .mcpServers
      | walk(if type == "string" then gsub("\\$\\{CLAUDE_PLUGIN_ROOT\\}"; $root) else . end)
    ' "$pj")"
    acc="$(jq -c --argjson add "$servers" '. + $add' <<<"$acc")"
  done <<< "$manifests"
  printf '%s' "$acc"
}

normalize_mcp_servers() {
  jq -c '
    def slow_command: ["npx", "bunx", "uvx", "pnpm dlx"];
    with_entries(
      .value = (
        if (.value.url? or .value.startup_timeout_sec?) then .value
        elif ((.value.command // "") as $cmd | (.key == "codebase-memory" or .key == "playwright" or (slow_command | index($cmd)))) then
          .value + {"startup_timeout_sec": 120}
        else .value end
      )
    )
  '
}

cmd_mcp() {
  need python3
  [[ -f "$MCP_MERGE_PY" ]] || { red "merge helper not found: $MCP_MERGE_PY"; exit 1; }
  local servers managed_names count out added skipped updated removed
  servers="$(collect_mcp_servers)"
  managed_names="$(collect_mcp_servers all | jq -c 'keys')"
  count="$(jq -r 'length' <<<"$servers")"
  if [[ "$count" == "0" && -z "${LEGION_SELECTED_PLUGINS_FILE:-}" ]]; then
    yellow "No MCP servers declared in the marketplace at $MARKETPLACE_ROOT"
    return 0
  fi
  green "Registering $count marketplace MCP server(s) into $CURSOR_MCP_CONFIG ..."
  out="$(printf '%s' "$servers" | python3 "$MCP_MERGE_PY" \
    --config "$CURSOR_MCP_CONFIG" --managed-names-json "$managed_names" "$@")"
  if [[ "$(jq -r 'has("error")' <<<"$out")" == "true" ]]; then
    red "  $(jq -r '.error' <<<"$out")"
    record_setup_failure "Cursor MCP registration failed." "$out"
    return 1
  fi
  added="$(jq -r '.added | join(", ")' <<<"$out")"
  skipped="$(jq -r '.skipped | join(", ")' <<<"$out")"
  updated="$(jq -r '.updated | join(", ")' <<<"$out")"
  removed="$(jq -r '.removed | join(", ")' <<<"$out")"
  [[ -n "$added"   ]] && green "  + added:   $added"
  [[ -n "$updated" ]] && green "  ~ updated: $updated"
  [[ -n "$removed" ]] && yellow "  - removed: $removed"
  [[ -n "$skipped" ]] && dim   "  = already present: $skipped"
  green "Cursor MCP servers in sync. Restart Cursor or reload Agent to pick them up."
}

cmd_agents() {
  need python3; need jq
  [[ -f "$BRIDGE_PY" ]] || { red "bridge helper not found: $BRIDGE_PY"; exit 1; }
  mkdir -p "$CURSOR_AGENTS"
  green "Bridging Legion commands, agents, and skills into Cursor agents ($CURSOR_AGENTS) ..."
  local out count pruned agents commands
  local bridge_args=(--root "$MARKETPLACE_ROOT" --out "$CURSOR_AGENTS" --skills-dir "$AGENTS_SKILLS")
  if [[ -n "${LEGION_SELECTED_PLUGINS_FILE:-}" ]]; then
    bridge_args+=(--plugins-file "$LEGION_SELECTED_PLUGINS_FILE")
  fi
  out="$(python3 "$BRIDGE_PY" "${bridge_args[@]}")"
  if [[ "$(jq -r 'has("error")' <<<"$out")" == "true" ]]; then
    red "  $(jq -r '.error' <<<"$out")"
    record_setup_failure "Cursor agent bridge failed." "$out"
    return 1
  fi
  if [[ "$(jq -r '.skipped // ""' <<<"$out")" == "empty-resolve-would-clobber" ]]; then
    yellow "Kept $(jq -r '.existing' <<<"$out") existing Cursor agents — marketplace root '$MARKETPLACE_ROOT' resolved no agents or commands."
    yellow "Point MARKETPLACE_ROOT at the marketplace that owns them, e.g. MARKETPLACE_ROOT=<root> legion-cursor-setup agents"
    return 0
  fi
  count="$(jq -r '.count' <<<"$out")"
  pruned="$(jq -r '.pruned' <<<"$out")"
  agents="$(jq -r '.agents | length' <<<"$out")"
  commands="$(jq -r '.commands | length' <<<"$out")"
  green "Bridged $count Cursor agents ($agents agents + $commands commands + skill runner; refreshed $pruned prior)."
}

cmd_verify() {
  need jq
  local ok=0
  green "Legion <-> Cursor readiness"

  if [[ -f "$CURSOR_MCP_CONFIG" ]]; then
    local want expected
    expected="$(collect_mcp_servers | normalize_mcp_servers)"
    want="$(jq -r 'keys[]' <<<"$expected" 2>/dev/null || true)"
    while IFS= read -r name; do
      [[ -z "$name" ]] && continue
      if jq -e --arg name "$name" '.mcpServers[$name]' "$CURSOR_MCP_CONFIG" >/dev/null 2>&1; then
        if jq -e --arg name "$name" --argjson expected "$expected" \
          '.mcpServers[$name] == $expected[$name]' "$CURSOR_MCP_CONFIG" >/dev/null 2>&1; then
          dim "  ok MCP $name registered"
        else
          yellow "  MCP $name registered but drifted - run: legion-cursor-setup mcp --force"; ok=1
        fi
      else
        yellow "  missing MCP $name - run: legion-cursor-setup mcp"; ok=1
      fi
    done <<<"$want"
  else
    yellow "  missing $CURSOR_MCP_CONFIG - run: legion-cursor-setup mcp"; ok=1
  fi

  local bridged
  bridged="$(find "$CURSOR_AGENTS" -maxdepth 1 -type f \( -name 'legion-agent-*.md' -o -name 'legion-cmd-*.md' \) 2>/dev/null | wc -l | tr -d ' ')"
  if [[ -f "$CURSOR_AGENTS/legion-skill-runner.md" && "$bridged" -gt 0 ]]; then
    dim "  ok $((bridged + 1)) Legion Cursor agents at $CURSOR_AGENTS"
  else
    yellow "  no Legion Cursor agents - run: MARKETPLACE_ROOT=<marketplace owning your agents> legion-cursor-setup agents"; ok=1
  fi

  local skills
  skills="$(count_dirs "$AGENTS_SKILLS")"
  if (( skills > 0 )); then dim "  ok $skills mirrored skills available to legion-skill-runner"; else yellow "  no mirrored skills at $AGENTS_SKILLS - run: legion-setup update"; ok=1; fi

  if command -v legion-cursor >/dev/null 2>&1; then dim "  ok legion-cursor on PATH"; else yellow "  legion-cursor not on PATH - run: legion-setup install"; ok=1; fi
  local cursor_bin
  cursor_bin="$(cursor_agent_bin)"
  if [[ -n "$cursor_bin" ]]; then
    dim "  ok Cursor Agent CLI present"
    if NO_OPEN_BROWSER=1 "$cursor_bin" status >/dev/null 2>&1; then
      dim "  ok Cursor Agent auth/status available"
    else
      yellow "  Cursor Agent auth/status check failed - run: agent login"; ok=1
    fi
  else
    yellow "  Cursor Agent CLI not found (install Cursor CLI for headless delegation)"; ok=1
  fi

  if (( ok == 0 )); then
    green "Legion is wired into Cursor."
  else
    yellow "Some checks failed (see above)."
    record_setup_failure "Cursor setup verification failed." "Run legion-setup cursor verify for details."
  fi
  return "$ok"
}

if [[ -n "${LEGION_SELECTED_PLUGINS_FILE:-}" && ! -f "$LEGION_SELECTED_PLUGINS_FILE" ]]; then
  red "selected plugins file not found: $LEGION_SELECTED_PLUGINS_FILE"
  exit 1
fi

case "${1:-all}" in
  mcp)     shift || true; cmd_mcp "$@" ;;
  agents)  cmd_agents ;;
  verify)  cmd_verify ;;
  all|"")  cmd_mcp; echo; cmd_agents; echo; cmd_verify || true ;;
  -h|--help) sed -n '2,14p' "$0" ;;
  *)       red "usage: legion-cursor-setup [all|mcp|agents|verify]"; exit 2 ;;
esac
