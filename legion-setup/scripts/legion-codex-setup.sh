#!/usr/bin/env bash
# legion-codex-setup — make Legion work natively on Codex CLI.
#
# Claude Code and Codex CLI both speak MCP, both read skills from ~/.agents/skills,
# and Legion adds `legion-claude` so a Codex-primary session can call Claude when
# it's worth it (with GPT-5.5 fallback). This script wires the Claude-side
# marketplace into Codex:
#
#   legion-codex-setup            # all: register MCPs + skills + bridge agents/commands + verify
#   legion-codex-setup mcp        # register every marketplace MCP into ~/.codex/config.toml
#   legion-codex-setup skills     # verify the cross-harness skill mirror (--fix to re-mirror)
#   legion-codex-setup bridge     # turn subagents + slash commands into Codex skills
#   legion-codex-setup verify     # read-only: MCPs / skills / bridges / legion-claude / codex
#
# Idempotent + non-destructive: MCP registration only APPENDS servers Codex doesn't
# already have (use --force to re-render). Nothing here touches your auth or models.
set -euo pipefail

HERE="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
# shellcheck disable=SC1091
source "$HERE/legion-marketplace-root.sh"
# Prefer an explicit root override, else walk up to the consumer marketplace, else
# fall back to the standalone legion-core layout.
MARKETPLACE_ROOT="$(legion_resolve_marketplace_root "$HERE" "$HERE/../..")"
CODEX_CONFIG="${CODEX_CONFIG:-$HOME/.codex/config.toml}"
AGENTS_HOME="${AGENTS_HOME:-$HOME/.agents}"
CODEX_SKILLS="${CODEX_SKILLS:-$HOME/.codex/skills}"
AGENTS_SKILLS="$AGENTS_HOME/skills"
MERGE_PY="$HERE/legion-codex-mcp-merge.py"
BRIDGE_PY="$HERE/legion-codex-bridge.py"

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
    --severity high --source "legion-codex-setup" --evidence "$evidence" >/dev/null 2>&1 || true
}

# Count immediate subdirectories, fail-safe under set -e/pipefail: find exits
# nonzero when the dir is absent, which would otherwise abort the script.
count_dirs() {
  [[ -d "$1" ]] || { printf '0'; return 0; }
  find "$1" -maxdepth 1 -mindepth 1 -type d 2>/dev/null | wc -l | tr -d ' '
}

# Collect every marketplace plugin's mcpServers into a single JSON object,
# resolving ${CLAUDE_PLUGIN_ROOT} to each plugin's absolute directory (Codex has
# no such variable, so the path must be concrete).
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
  [[ -f "$MERGE_PY" ]] || { red "merge helper not found: $MERGE_PY"; exit 1; }
  local servers count out
  servers="$(collect_mcp_servers)"
  count="$(jq -r 'length' <<<"$servers")"
  if [[ "$count" == "0" ]]; then
    yellow "No MCP servers declared in the marketplace at $MARKETPLACE_ROOT"
    return 0
  fi
  green "Registering $count marketplace MCP server(s) into $CODEX_CONFIG …"
  out="$(printf '%s' "$servers" | python3 "$MERGE_PY" --config "$CODEX_CONFIG" "$@")"
  local added skipped updated
  added="$(jq -r '.added | join(", ")' <<<"$out")"
  skipped="$(jq -r '.skipped | join(", ")' <<<"$out")"
  updated="$(jq -r '.updated | join(", ")' <<<"$out")"
  [[ -n "$added"   ]] && green  "  + added:   $added"
  [[ -n "$updated" ]] && green  "  ~ updated: $updated"
  [[ -n "$skipped" ]] && dim    "  = already present: $skipped"
  green "✓ Codex MCP servers in sync. Restart codex (or reload) to pick up new servers."
}

cmd_skills() {
  local fix=0
  [[ "${1:-}" == "--fix" ]] && fix=1
  if [[ ! -d "$AGENTS_SKILLS" ]]; then
    yellow "No cross-harness skill source at $AGENTS_SKILLS."
    yellow "Run 'legion-setup update' first — it mirrors the marketplace skills there."
    return 0
  fi
  local src_n dst_n
  src_n="$(count_dirs "$AGENTS_SKILLS")"
  dst_n="$(count_dirs "$CODEX_SKILLS")"
  green "Skill mirror: $AGENTS_SKILLS ($src_n) → $CODEX_SKILLS ($dst_n)"
  if (( dst_n < src_n )) && (( fix == 1 )); then
    yellow "Re-mirroring $src_n skills into $CODEX_SKILLS …"
    mkdir -p "$CODEX_SKILLS"
    # Copy each skill dir; -a preserves the SKILL.md tree. Existing dirs are refreshed.
    local d
    for d in "$AGENTS_SKILLS"/*/; do
      [[ -d "$d" ]] || continue
      # Strip the trailing slash: BSD `cp -a src/` copies the CONTENTS of src,
      # not the directory itself — we want the skill dir preserved by name.
      cp -a "${d%/}" "$CODEX_SKILLS/"
    done
    dst_n="$(count_dirs "$CODEX_SKILLS")"
    green "✓ Mirrored. $CODEX_SKILLS now has $dst_n skills."
  elif (( dst_n < src_n )); then
    yellow "  $((src_n - dst_n)) skill(s) not yet mirrored to Codex. Run: legion-codex-setup skills --fix"
  else
    green "✓ Skills present for Codex."
  fi
}

cmd_bridge() {
  need python3; need jq
  [[ -f "$BRIDGE_PY" ]] || { red "bridge helper not found: $BRIDGE_PY"; exit 1; }
  green "Bridging subagents + slash commands into Codex skills ($CODEX_SKILLS) …"
  local out agents commands pruned count
  out="$(python3 "$BRIDGE_PY" --root "$MARKETPLACE_ROOT" --out "$CODEX_SKILLS")"
  if [[ "$(jq -r 'has("error")' <<<"$out")" == "true" ]]; then
    red "  $(jq -r '.error' <<<"$out")"
    record_setup_failure "Codex bridge generation failed." "$out"
    return 1
  fi
  count="$(jq -r '.count' <<<"$out")"
  pruned="$(jq -r '.pruned' <<<"$out")"
  agents="$(jq -r '.agents | length' <<<"$out")"
  commands="$(jq -r '.commands | length' <<<"$out")"
  green "✓ Bridged $count skills ($agents agents + $commands commands; refreshed $pruned prior)."
  dim "  Codex picks these up by skill-trigger: the user describes the task instead of typing a slash command."
}

cmd_verify() {
  need jq
  local ok=0
  green "Legion ↔ Codex readiness"
  # 1) MCP servers registered?
  local want miss=()
  want="$(collect_mcp_servers | jq -r 'keys[]' 2>/dev/null || true)"
  if [[ -f "$CODEX_CONFIG" ]]; then
    while IFS= read -r name; do
      [[ -z "$name" ]] && continue
      if grep -qE "^\[mcp_servers\.${name}\]" "$CODEX_CONFIG"; then
        dim "  ✓ MCP $name registered"
      else
        miss+=("$name"); ok=1
      fi
    done <<<"$want"
    ((${#miss[@]})) && yellow "  ✗ MCP not registered: ${miss[*]} — run: legion-codex-setup mcp"
  else
    yellow "  ✗ $CODEX_CONFIG not found (is Codex CLI installed?)"; ok=1
  fi
  # 2) skill mirror present?
  local dst_n
  dst_n="$(count_dirs "$CODEX_SKILLS")"
  if (( dst_n > 0 )); then dim "  ✓ $dst_n skills mirrored to $CODEX_SKILLS"; else yellow "  ✗ no skills at $CODEX_SKILLS — run: legion-codex-setup skills --fix"; ok=1; fi
  # 2b) bridged agents/commands present?
  local bridged
  bridged="$(find "$CODEX_SKILLS" -maxdepth 1 -type d \( -name 'legion-agent-*' -o -name 'legion-cmd-*' \) 2>/dev/null | wc -l | tr -d ' ')"
  if (( bridged > 0 )); then dim "  ✓ $bridged subagents/commands bridged to skills"; else yellow "  ✗ no bridged agents/commands — run: legion-codex-setup bridge"; ok=1; fi
  # 3) legion-claude reachable (the reverse-delegate)?
  if command -v legion-claude >/dev/null 2>&1; then dim "  ✓ legion-claude on PATH (Codex can call Claude with GPT fallback)"; else yellow "  ✗ legion-claude not on PATH — run: legion-setup install"; ok=1; fi
  # 4) codex itself present?
  if command -v codex >/dev/null 2>&1; then dim "  ✓ codex CLI present"; else yellow "  ✗ codex CLI not found"; ok=1; fi
  if (( ok == 0 )); then
    green "✓ Legion is wired into Codex."
  else
    yellow "Some checks failed (see above)."
    record_setup_failure "Codex setup verification failed." "Run legion-setup codex verify for details."
  fi
  return "$ok"
}

case "${1:-all}" in
  mcp)     shift || true; cmd_mcp "$@" ;;
  skills)  shift || true; cmd_skills "${1:-}" ;;
  bridge)  cmd_bridge ;;
  verify)  cmd_verify ;;
  all|"")  cmd_mcp; echo; cmd_skills --fix; echo; cmd_bridge; echo; cmd_verify || true ;;
  -h|--help) sed -n '2,22p' "$0" ;;
  *)       red "usage: legion-codex-setup [all|mcp|skills [--fix]|bridge|verify]"; exit 2 ;;
esac
