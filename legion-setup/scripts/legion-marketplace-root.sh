#!/usr/bin/env bash

_legion_abs_dir_or_raw() {
  local path="$1"
  if [[ "$path" == "~" ]]; then
    path="$HOME"
  elif [[ "${path:0:1}" == \~ && "${path:1:1}" == / ]]; then
    path="$HOME/${path:2}"
  fi
  if [[ -d "$path" ]] && cd "$path" >/dev/null 2>&1; then
    pwd
  else
    printf '%s\n' "$path"
  fi
}

legion_resolve_marketplace_root() {
  local here="$1"
  local fallback="${2:-$here/../..}"
  local override="${MARKETPLACE_ROOT:-${LEGION_MARKETPLACE_ROOT:-}}"
  local current="$here"
  local parent=""

  if [[ -n "$override" ]]; then
    _legion_abs_dir_or_raw "$override"
    return 0
  fi

  while [[ -n "$current" ]]; do
    if [[ -f "$current/.claude-plugin/marketplace.json" ]]; then
      printf '%s\n' "$current"
      return 0
    fi
    parent="$(dirname "$current")"
    [[ "$parent" == "$current" ]] && break
    current="$parent"
  done

  _legion_abs_dir_or_raw "$fallback"
}
