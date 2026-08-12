#!/usr/bin/env bash
# Readiness and narrowly scoped skill discovery setup for Pi and Hermes.
# Pi consumes ~/.agents/skills directly. Hermes does not, so Legion manages one
# symlink in ~/.hermes/skills without rewriting Hermes configuration.
set -euo pipefail

KIND="${LEGION_PRIMARY_SETUP_KIND:?LEGION_PRIMARY_SETUP_KIND must be pi or hermes}"
case "$KIND" in pi|hermes) ;; *) printf 'invalid Legion primary setup kind\n' >&2; exit 2 ;; esac

AGENTS_HOME="${AGENTS_HOME:-$HOME/.agents}"
SKILLS_DIR="${LEGION_SKILLS_DIR:-$AGENTS_HOME/skills}"
MODE_SKILL="legion-${KIND}-mode"
HERMES_HOME="${HERMES_HOME:-$HOME/.hermes}"
HERMES_SKILLS_DIR="${HERMES_SKILLS_DIR:-$HERMES_HOME/skills}"
HERMES_LINK_MANIFEST="$AGENTS_HOME/.managed-by-legion-core/hermes-skill-link.json"

green() { printf '\033[0;32m%s\033[0m\n' "$*"; }
yellow() { printf '\033[0;33m%s\033[0m\n' "$*"; }
red() { printf '\033[0;31m%s\033[0m\n' "$*" >&2; }
dim() { printf '\033[0;90m%s\033[0m\n' "$*"; }

discoverable_skill_path() {
  if [[ "$KIND" == hermes ]]; then
    printf '%s/%s' "$HERMES_SKILLS_DIR" "$MODE_SKILL"
  else
    printf '%s/%s' "$SKILLS_DIR" "$MODE_SKILL"
  fi
}

install_hermes_skill_link() {
  [[ "$KIND" == hermes ]] || return 0
  local source="$SKILLS_DIR/$MODE_SKILL" destination="$HERMES_SKILLS_DIR/$MODE_SKILL"
  [[ -f "$source/SKILL.md" ]] || {
    red "missing shared $MODE_SKILL at $source; re-run the Legion installer first"
    return 1
  }
  mkdir -p "$HERMES_SKILLS_DIR"
  if [[ -L "$destination" ]]; then
    if [[ "$(readlink "$destination")" == "$source" ]]; then
      record_hermes_skill_link "$source" "$destination"
      return 0
    fi
    red "$destination is already a different symlink; refusing to replace it"
    return 1
  fi
  if [[ -e "$destination" ]]; then
    red "$destination already exists and is not Legion-managed; refusing to replace it"
    return 1
  fi
  ln -s "$source" "$destination"
  record_hermes_skill_link "$source" "$destination"
  green "Linked $destination -> $source"
}

record_hermes_skill_link() {
  local source="$1" destination="$2" directory temp
  directory="${HERMES_LINK_MANIFEST%/*}"
  mkdir -p "$directory"
  temp="$(umask 077; mktemp "$directory/.hermes-skill-link.tmp.XXXXXX")" || return 1
  if ! jq -cn --arg schema 'legion.hermes-skill-link.v1' --arg source "$source" \
      --arg destination "$destination" '{schema:$schema,source:$source,destination:$destination}' > "$temp"; then
    rm -f "$temp"
    return 1
  fi
  chmod 600 "$temp" || { rm -f "$temp"; return 1; }
  mv -f "$temp" "$HERMES_LINK_MANIFEST"
}

cmd_verify() {
  local failed=0
  printf 'Legion %s readiness (read-only)\n' "$KIND"

  if command -v "$KIND" >/dev/null 2>&1; then
    dim "  ok $KIND CLI on PATH"
  else
    yellow "  missing $KIND CLI on PATH - install it before running Legion work"
    failed=1
  fi

  if command -v "legion-$KIND" >/dev/null 2>&1; then
    dim "  ok legion-$KIND adapter on PATH"
  else
    yellow "  missing legion-$KIND adapter on PATH - re-run legion-setup install or add ~/.agents/bin to PATH"
    failed=1
  fi

  if command -v sandbox-exec >/dev/null 2>&1 || command -v bwrap >/dev/null 2>&1 \
      || command -v bubblewrap >/dev/null 2>&1; then
    dim "  ok filesystem write sandbox available"
  else
    yellow "  missing filesystem write sandbox - macOS provides sandbox-exec; on Linux install bubblewrap"
    failed=1
  fi

  local skill_path
  skill_path="$(discoverable_skill_path)"
  if [[ "$KIND" == hermes && -L "$skill_path" \
      && "$(readlink "$skill_path")" == "$SKILLS_DIR/$MODE_SKILL" \
      && -f "$SKILLS_DIR/$MODE_SKILL/SKILL.md" ]]; then
    dim "  ok $MODE_SKILL discoverable through the managed link at $skill_path"
  elif [[ "$KIND" == pi && -f "$skill_path/SKILL.md" ]]; then
    dim "  ok $MODE_SKILL discoverable at $skill_path"
  else
    if [[ "$KIND" == hermes ]]; then
      yellow "  missing $MODE_SKILL in $HERMES_SKILLS_DIR - run legion-setup hermes"
    else
      yellow "  missing $MODE_SKILL in $SKILLS_DIR - re-run legion-setup install (it only manages Legion-owned symlinks)"
    fi
    failed=1
  fi

  if command -v legion-route >/dev/null 2>&1 && legion-route --list-executors 2>/dev/null \
    | jq -e --arg kind "$KIND" 'index($kind) != null' >/dev/null; then
    dim "  ok $KIND registered as a coding executor"
  else
    yellow "  unable to confirm $KIND in legion-route --list-executors - ensure the current Legion bin directory is on PATH"
    failed=1
  fi

  return "$failed"
}

cmd_all() {
  if [[ "$KIND" == hermes ]]; then
    install_hermes_skill_link
    green "Legion Hermes uses a managed link into the shared $SKILLS_DIR catalog; Hermes configuration is unchanged."
  else
    green "Legion Pi uses the shared $SKILLS_DIR catalog directly; no native configuration is changed."
  fi
  cmd_verify
}

usage() {
  printf 'usage: legion-%s-setup [all|verify]\n' "$KIND"
}

case "${1:-all}" in
  all|"") cmd_all ;;
  verify) cmd_verify ;;
  -h|--help|help) usage ;;
  *) red "usage: legion-$KIND-setup [all|verify]"; exit 2 ;;
esac
