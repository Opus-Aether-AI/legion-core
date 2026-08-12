#!/usr/bin/env bash
# Collision-resistant Legion run identities shared by every harness adapter.

legion_new_run_id() {
  local stamp entropy="" od_cmd="" tr_cmd="" uuid_cmd="" uuid=""
  stamp="$(date -u +%Y%m%d-%H%M%S)" || return 1
  od_cmd="$(command -v od 2>/dev/null || true)"
  tr_cmd="$(command -v tr 2>/dev/null || true)"
  uuid_cmd="$(command -v uuidgen 2>/dev/null || true)"
  [[ -n "$od_cmd" ]] || { [[ ! -x /usr/bin/od ]] || od_cmd=/usr/bin/od; }
  [[ -n "$tr_cmd" ]] || { [[ ! -x /usr/bin/tr ]] || tr_cmd=/usr/bin/tr; }
  [[ -n "$uuid_cmd" ]] || { [[ ! -x /usr/bin/uuidgen ]] || uuid_cmd=/usr/bin/uuidgen; }
  if [[ -r /dev/urandom && -n "$od_cmd" && -n "$tr_cmd" ]]; then
    entropy="$(LC_ALL=C "$od_cmd" -An -N12 -tx1 /dev/urandom 2>/dev/null | "$tr_cmd" -d '[:space:]')" || return 1
  elif [[ -n "$uuid_cmd" && -n "$tr_cmd" ]]; then
    uuid="$($uuid_cmd)" || return 1
    uuid="${uuid//-/}"
    entropy="$(printf '%s' "${uuid:0:24}" | "$tr_cmd" '[:upper:]' '[:lower:]')" || return 1
  else
    printf 'legion: secure run-id entropy is unavailable (need /dev/urandom+od or uuidgen)\n' >&2
    return 1
  fi
  [[ "$entropy" =~ ^[0-9a-f]{24}$ ]] || return 1
  printf '%s-%s' "$stamp" "$entropy"
}
