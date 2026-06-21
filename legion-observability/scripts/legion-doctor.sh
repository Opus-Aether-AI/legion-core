#!/usr/bin/env bash
# legion-doctor — verify a Legion install is wired correctly. Exits nonzero on any
# hard-check failure (CI-usable). codex/router checks are warnings, not failures.
#
#   legion-doctor [--repo DIR] [--only CHECK] [--record-failures]
#   checks: marketplace-schema plugins frontmatter descriptions mcp bridges
#           costs telemetry-schema codex router
#
# --record-failures: for every hard FAIL, also call `legion-self-learn record`
#   so static marketplace defects surface as self-learning hints (no-op if
#   legion-self-learn isn't on PATH). Off by default; the daily refresh sets it.
#
# Two directories matter, and they are NOT the same thing:
#   * LEGION_ROOT — where Legion's OWN files live (marketplace.json, costs.json,
#     the telemetry schema). Auto-resolved from this script's install location so
#     the install-checks are correct no matter the working directory or --repo.
#     Override with the LEGION_ROOT env var for tests / non-standard layouts.
#   * REPO (--repo) — the repo scanned for SKILL.md frontmatter. Defaults to
#     LEGION_ROOT. Pointing it at a product repo (e.g. a webapp) is fine and only
#     affects the frontmatter scan — it no longer false-fails the Legion-internal
#     checks just because that repo lacks Legion's files.
#
# NOTE: intentionally NOT `set -e` — checks must all run and aggregate.
set -uo pipefail

_self="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_default_root="$(cd "$_self/../.." && pwd)"   # plugin lives at <root>/legion-observability/scripts

REPO=""
ONLY=""
RECORD_FAILURES=0
JSON=0
ROUTER_PORT="${ROUTER_PORT:-8082}"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --repo) REPO="$2"; shift 2 ;;
    --only) ONLY="$2"; shift 2 ;;
    --record-failures) RECORD_FAILURES=1; shift ;;
    --json) JSON=1; shift ;;
    -h|--help) echo "usage: legion-doctor [--repo DIR] [--record-failures] [--json] [--only marketplace-schema|plugins|frontmatter|descriptions|mcp|bridges|costs|telemetry-schema|codex|router]"; exit 0 ;;
    *) echo "legion-doctor: unknown arg '$1'" >&2; exit 2 ;;
  esac
done

# Legion install root: env override → git toplevel of this script → path fallback.
LEGION_ROOT="${LEGION_ROOT:-$(git -C "$_self" rev-parse --show-toplevel 2>/dev/null || echo "$_default_root")}"
# Frontmatter scan target defaults to the install root.
[[ -n "$REPO" ]] || REPO="$LEGION_ROOT"

# --json: emit one record per result as a JSON array on stdout (human PASS/FAIL/
# WARN lines go to stderr so stdout stays parseable). legion-heal consumes this
# to know what to fix. _CHECK names the active check for attribution.
_CHECK=""
_FINDINGS_FILE="$(mktemp)"
trap 'rm -f "$_FINDINGS_FILE"' EXIT

FAILS=0
WARNS=0
_line() { if [[ "$JSON" == "1" ]]; then printf '%s\n' "$*" >&2; else printf '%s\n' "$*"; fi; }
_emit() {  # severity message entity
  [[ "$JSON" == "1" ]] || return 0
  jq -cn --arg c "$_CHECK" --arg s "$1" --arg m "$2" --arg e "${3:-}" \
    '{check:$c, severity:$s, message:$m, entity:$e}' >> "$_FINDINGS_FILE"
}
# fail "<message>" ["<entity>"] — entity (TYPE:NAME) routes the self-learning
# record; defaults to tool:legion-doctor.
_maybe_record() {
  [[ "$RECORD_FAILURES" == "1" ]] || return 0
  command -v legion-self-learn >/dev/null 2>&1 || return 0
  legion-self-learn record \
    --entity "${2:-tool:legion-doctor}" --summary "$1" \
    --severity high --source legion-doctor >/dev/null 2>&1 || true
}
pass() { _line "$(printf '\033[0;32mPASS\033[0m %s' "$*")"; _emit pass "$*" ""; }
fail() { _line "$(printf '\033[0;31mFAIL\033[0m %s' "$1")"; FAILS=$((FAILS + 1)); _emit fail "$1" "${2:-}"; _maybe_record "$1" "${2:-}"; }
warn() { _line "$(printf '\033[0;33mWARN\033[0m %s' "$*")"; WARNS=$((WARNS + 1)); _emit warn "$*" ""; }

check_marketplace_schema() {
  local mf="$LEGION_ROOT/.claude-plugin/marketplace.json"
  if [[ -f "$mf" ]] && jq -e '.name and .owner and .version and (.plugins | type == "array")' "$mf" >/dev/null 2>&1; then
    pass "marketplace.json schema valid ($(jq -r '.plugins | length' "$mf") plugins)"
  else
    fail "marketplace.json missing or invalid: $mf"
  fi
}

check_plugins() {
  local mf="$LEGION_ROOT/.claude-plugin/marketplace.json" miss=0 name src dir
  [[ -f "$mf" ]] || { fail "no marketplace.json to resolve plugins"; return; }
  while read -r name src; do
    dir="$LEGION_ROOT/${src#./}"
    if [[ ! -d "$dir" ]]; then
      fail "plugin '$name' source missing: $src"; miss=1; continue
    fi
    if [[ ! -f "$dir/.claude-plugin/plugin.json" && ! -f "$dir/SKILL.md" ]]; then
      fail "plugin '$name' has neither plugin.json nor SKILL.md"; miss=1
    fi
  done < <(jq -r '.plugins[] | select(.source | type == "string") | "\(.name) \(.source)"' "$mf")
  [[ "$miss" -eq 0 ]] && pass "all plugin sources resolve + have a manifest/SKILL"
}

check_frontmatter() {
  local bad=0 f
  while IFS= read -r f; do
    if ! head -1 "$f" | grep -q '^---'; then
      fail "SKILL.md missing frontmatter: ${f#"$REPO/"}"; bad=1; continue
    fi
    grep -qE '^name:[[:space:]]*\S' "$f"        || { fail "SKILL.md missing name: ${f#"$REPO/"}"; bad=1; }
    grep -qE '^description:[[:space:]]*\S' "$f"  || { fail "SKILL.md missing description: ${f#"$REPO/"}"; bad=1; }
  done < <(find "$REPO" -name SKILL.md -not -path '*/node_modules/*' -not -path '*/.git/*' 2>/dev/null)
  [[ "$bad" -eq 0 ]] && pass "all SKILL.md frontmatter has name + description"
}

check_costs() {
  # Locate costs.json wherever legion-router lives — top-level (standalone core)
  # or under vendored/ (when consumed by a downstream marketplace). When the
  # engine isn't present at all (a consumer that installs it as a dependency),
  # this is WARN, not FAIL — the engine is validated in its own repo.
  local cf; cf="$(find "$LEGION_ROOT" -path '*/legion-router/config/costs.json' -not -path '*/.git/*' 2>/dev/null | head -1)"
  if [[ -z "$cf" ]]; then
    warn "costs.json not present (legion-router engine not vendored here — checked in legion-core)"
  elif jq -e '(.models | type == "array") and (.default | type == "object")' "$cf" >/dev/null 2>&1; then
    pass "costs.json valid ($(jq -r '.models | length' "$cf") model rows)"
  else
    fail "costs.json invalid: $cf"
  fi
}

check_telemetry_schema() {
  local sf; sf="$(find "$LEGION_ROOT" -path '*/legion-observability/schema/legion.span.v1.schema.json' -not -path '*/.git/*' 2>/dev/null | head -1)"
  if [[ -z "$sf" ]]; then
    warn "telemetry schema not present (legion-observability engine not vendored here — checked in legion-core)"
  elif jq -e '.title == "legion.span.v1"' "$sf" >/dev/null 2>&1; then
    pass "telemetry schema present (legion.span.v1)"
  else
    fail "telemetry schema invalid: $sf"
  fi
}

# ── descriptions: every SKILL.md description survives a line-based read ──
# A `description: >` / `| ` block scalar collapses to just ">"/"|" under the
# line-based frontmatter readers used by the Cursor bridge and some skill
# loaders — blanking the description + auto-trigger. Empty descriptions fail too.
_desc_value() {
  awk '
    NR==1 && $0 !~ /^---[ \t]*$/ { exit }
    /^---[ \t]*$/ { f++; if (f==2) exit; next }
    f==1 && /^[ \t]*description:/ {
      sub(/^[ \t]*description:[ \t]*/, ""); print; exit
    }' "$1"
}
check_descriptions() {
  local bad=0 f val rel
  while IFS= read -r f; do
    rel="${f#"$LEGION_ROOT/"}"
    val="$(_desc_value "$f")"
    if [[ -z "${val//[[:space:]]/}" ]]; then
      fail "SKILL.md empty/missing description: $rel" "skill:$(basename "$(dirname "$f")")"; bad=1; continue
    fi
    if [[ "$val" =~ ^[\>\|][+-]?[[:space:]]*$ ]]; then
      fail "SKILL.md block-scalar description ('$val') blanks line-based readers: $rel" \
        "skill:$(basename "$(dirname "$f")")"; bad=1
    fi
  done < <(find "$LEGION_ROOT" -name SKILL.md -not -path '*/node_modules/*' -not -path '*/.git/*' 2>/dev/null)
  [[ "$bad" -eq 0 ]] && pass "all SKILL.md descriptions are single-line + non-empty"
}

# ── mcp: every declared MCP server is actually resolvable ───────────────
# npx/bunx packages must exist on the registry; local-command servers must
# point at a file that exists + is executable. Network/tool gaps WARN (so the
# check still gates offline); only a definitive 404 / missing binary FAILs.
_pkg_from_args() {  # first non-flag arg, version spec stripped
  jq -r '[.[] | select(startswith("-") | not)][0] // ""' <<<"$1" | sed -E 's/@[^@/]*$//'
}
check_mcp() {
  local bad=0 pj name plugindir server cmd args url pkg expanded
  while IFS= read -r pj; do
    jq -e 'has("mcpServers") and (.mcpServers | length > 0)' "$pj" >/dev/null 2>&1 || continue
    plugindir="$(cd "$(dirname "$pj")/.." && pwd)"
    name="$(jq -r '.name // "?"' "$pj")"
    while IFS= read -r server; do
      url="$(jq -r --arg s "$server" '.mcpServers[$s].url // ""' "$pj")"
      [[ -n "$url" ]] && continue   # remote MCP — can't validate without auth
      cmd="$(jq -r --arg s "$server" '.mcpServers[$s].command // ""' "$pj")"
      args="$(jq -c --arg s "$server" '.mcpServers[$s].args // []' "$pj")"
      case "$cmd" in
        npx|bunx|pnpm\ dlx|uvx)
          pkg="$(_pkg_from_args "$args")"
          [[ -z "$pkg" ]] && { warn "$name:$server — $cmd with no package arg"; continue; }
          if ! command -v npm >/dev/null 2>&1; then warn "$name:$server — npm absent, can't verify $pkg"; continue; fi
          # Capture output + exit separately: piping npm into grep would mask
          # grep's match under `set -o pipefail` (npm's non-zero exit wins).
          local nout nrc
          nout="$(npm view "$pkg" version 2>&1)"; nrc=$?
          if [[ $nrc -eq 0 ]]; then
            : # resolves
          elif grep -qE 'E404|404 Not Found' <<<"$nout"; then
            fail "$name:$server — npm package does not exist: $pkg" "plugin:$name"; bad=1
          else
            warn "$name:$server — could not reach registry to verify $pkg"
          fi
          ;;
        */*|*\$\{*)
          expanded="${cmd//\$\{CLAUDE_PLUGIN_ROOT\}/$plugindir}"
          # shellcheck disable=SC2016  # matching a literal ${VAR}, not expanding
          if [[ "$expanded" == *'${'* ]]; then warn "$name:$server — unexpandable command: $cmd"; continue; fi
          [[ -x "$expanded" ]] || { fail "$name:$server — local MCP command missing/not executable: $expanded" "plugin:$name"; bad=1; }
          ;;
        "") warn "$name:$server — no command and no url" ;;
        *)  command -v "$cmd" >/dev/null 2>&1 || warn "$name:$server — command not on PATH: $cmd" ;;
      esac
    done < <(jq -r '.mcpServers | keys[]' "$pj")
  done < <(find "$LEGION_ROOT" -maxdepth 4 -path '*/.claude-plugin/plugin.json' -not -path '*/.git/*' 2>/dev/null)
  [[ "$bad" -eq 0 ]] && pass "all declared MCP servers resolve (or warn-skipped)"
}

# ── bridges: the Codex + Cursor MCP merges accept every plugin's servers ─
# Guards the cross-harness path so an MCP block that breaks Codex/Cursor is
# caught here, not in a user's config. Needs python3 (WARN-skip otherwise).
check_bridges() {
  local setup; setup="$(dirname "$(find "$LEGION_ROOT" -path '*/legion-setup/scripts/legion-codex-mcp-merge.py' -not -path '*/.git/*' 2>/dev/null | head -1)")"
  [[ "$setup" == "." || -z "$setup" ]] && setup="$LEGION_ROOT/legion-setup/scripts"
  local codex_merge="$setup/legion-codex-mcp-merge.py" cursor_merge="$setup/legion-cursor-mcp-merge.py"
  if ! command -v python3 >/dev/null 2>&1; then warn "python3 absent — skipping bridge merge check"; return; fi
  [[ -f "$codex_merge" && -f "$cursor_merge" ]] || { warn "bridge merge scripts not found"; return; }
  # Collect every plugin's mcpServers, expanding ${CLAUDE_PLUGIN_ROOT}, into one object.
  local combined tmp; tmp="$(mktemp -d)"
  combined="$(
    find "$LEGION_ROOT" -maxdepth 4 -path '*/.claude-plugin/plugin.json' -not -path '*/.git/*' 2>/dev/null | sort | while IFS= read -r pj; do
      jq -e 'has("mcpServers")' "$pj" >/dev/null 2>&1 || continue
      root="$(cd "$(dirname "$pj")/.." && pwd)"
      jq --arg r "$root" '.mcpServers | walk(if type=="string" then gsub("\\$\\{CLAUDE_PLUGIN_ROOT\\}"; $r) else . end)' "$pj"
    done | jq -s 'add // {}'
  )"
  local n; n="$(echo "$combined" | jq 'length')"
  _try_bridge() {  # label  script  config-path
    local out rc
    out="$(echo "$combined" | python3 "$2" --config "$3" --dry-run 2>&1)"; rc=$?
    if [[ $rc -ne 0 ]] || echo "$out" | grep -q '"error"'; then
      fail "$1 bridge rejects current MCP servers: $out" "tool:legion-$1-bridge"
    else
      pass "$1 bridge accepts all MCP servers ($n total)"
    fi
  }
  _try_bridge codex  "$codex_merge"  "$tmp/c.toml"
  _try_bridge cursor "$cursor_merge" "$tmp/c.json"
  rm -rf "$tmp"
}

check_codex() {
  if command -v codex >/dev/null 2>&1; then
    if [[ -f "$HOME/.codex/auth.json" ]]; then
      pass "codex present + authenticated"
    else
      warn "codex present but not authenticated (~/.codex/auth.json missing) — GPT delegation will fail"
    fi
  else
    warn "codex CLI not found — GPT delegation unavailable"
  fi
}

check_router() {
  if curl -sf -m 2 "http://127.0.0.1:$ROUTER_PORT/health" >/dev/null 2>&1; then
    pass "router responding on 127.0.0.1:$ROUTER_PORT"
  else
    warn "router not running on :$ROUTER_PORT (optional — legion-router start)"
  fi
}

run_one() {
  _CHECK="$1"
  case "$1" in
    marketplace-schema) check_marketplace_schema ;;
    plugins)            check_plugins ;;
    frontmatter)        check_frontmatter ;;
    descriptions)       check_descriptions ;;
    mcp)                check_mcp ;;
    bridges)            check_bridges ;;
    costs)              check_costs ;;
    telemetry-schema)   check_telemetry_schema ;;
    codex)              check_codex ;;
    router)             check_router ;;
    *) echo "legion-doctor: unknown check '$1'" >&2; exit 2 ;;
  esac
}

[[ "$REPO" != "$LEGION_ROOT" ]] && \
  _line "$(printf '\033[0;36mINFO\033[0m frontmatter scan: %s · Legion install: %s' "$REPO" "$LEGION_ROOT")"

if [[ -n "$ONLY" ]]; then
  run_one "$ONLY"
else
  for c in marketplace-schema plugins frontmatter descriptions mcp bridges costs telemetry-schema codex router; do
    run_one "$c"
  done
fi

if [[ "$JSON" == "1" ]]; then
  if [[ -s "$_FINDINGS_FILE" ]]; then jq -cs '.' "$_FINDINGS_FILE"; else echo '[]'; fi
else
  echo "── ${FAILS} fail, ${WARNS} warn ──"
fi
[[ "$FAILS" -eq 0 ]] || exit 1
