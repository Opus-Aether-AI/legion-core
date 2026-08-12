#!/usr/bin/env bash
# Collision-resistant Legion run identities shared by every harness adapter.

legion_new_run_id() {
  local stamp entropy=""
  stamp="$(date -u +%Y%m%d-%H%M%S)" || return 1
  if [[ -r /dev/urandom ]] && command -v od >/dev/null 2>&1; then
    entropy="$(LC_ALL=C od -An -N12 -tx1 /dev/urandom 2>/dev/null | tr -d '[:space:]')" || return 1
  elif command -v uuidgen >/dev/null 2>&1; then
    entropy="$(uuidgen | tr -d '-' | tr '[:upper:]' '[:lower:]' | cut -c1-24)" || return 1
  else
    printf 'legion: secure run-id entropy is unavailable (need /dev/urandom+od or uuidgen)\n' >&2
    return 1
  fi
  [[ "$entropy" =~ ^[0-9a-f]{24}$ ]] || return 1
  printf '%s-%s' "$stamp" "$entropy"
}
