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

  # Walk to the OUTERMOST marketplace.json, not the first one found. When
  # legion-core is vendored (consumer/vendored/legion-core/...), the nearest
  # match going up is legion-core's OWN marketplace.json — but we want the
  # consumer's, which sits at the repo root above it. The outermost match is the
  # consumer. Standalone legion-core has a single match (its own root), so this
  # stays correct there too. Use MARKETPLACE_ROOT to override for odd layouts.
  local match=""
  while [[ -n "$current" ]]; do
    [[ -f "$current/.claude-plugin/marketplace.json" ]] && match="$current"
    parent="$(dirname "$current")"
    [[ "$parent" == "$current" ]] && break
    current="$parent"
  done

  if [[ -n "$match" ]]; then
    _legion_abs_dir_or_raw "$match"
    return 0
  fi

  _legion_abs_dir_or_raw "$fallback"
}
