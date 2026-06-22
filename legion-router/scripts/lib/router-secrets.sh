#!/usr/bin/env bash

# Portable secret storage for legion-router. Resolution order is:
#   1. macOS Keychain via `security` on Darwin
#   2. libsecret via `secret-tool` when available
#   3. per-secret 0600 files under ${XDG_CONFIG_HOME:-~/.config}/legion/router
#
# The caller is responsible for honoring direct env vars first.

legion_router_secret_env() {
  case "${1:-}" in
    anthropic) printf 'ANTHROPIC_API_KEY\n' ;;
    minimax) printf 'MINIMAX_AUTH_TOKEN\n' ;;
    *) return 1 ;;
  esac
}

legion_router_secret_service() {
  case "${1:-}" in
    anthropic) printf 'legion-anthropic\n' ;;
    minimax) printf 'legion-minimax\n' ;;
    *) return 1 ;;
  esac
}

legion_router_secret_label() {
  case "${1:-}" in
    anthropic) printf 'Legion Router Anthropic API key\n' ;;
    minimax) printf 'Legion Router MiniMax auth token\n' ;;
    *) return 1 ;;
  esac
}

legion_router_secret_config_dir() {
  printf '%s\n' "${LEGION_ROUTER_CONFIG_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/legion/router}"
}

legion_router_secret_file_path() {
  local name="${1:?secret name required}"
  local dir
  dir="$(legion_router_secret_config_dir)"
  printf '%s/%s\n' "$dir" "$(legion_router_secret_env "$name" | tr '[:upper:]' '[:lower:]')"
}

legion_router_read_secret_file() {
  local path
  path="$(legion_router_secret_file_path "$1")"
  [[ -r "$path" ]] || return 1
  tr -d '\r' <"$path"
}

legion_router_write_secret_file() {
  local name="${1:?secret name required}" value="${2:-}" dir path
  [[ -n "$value" ]] || return 1
  dir="$(legion_router_secret_config_dir)"
  path="$(legion_router_secret_file_path "$name")"
  mkdir -p "$dir"
  chmod 700 "$dir" 2>/dev/null || true
  (umask 077; printf '%s' "$value" >"$path")
  chmod 600 "$path" 2>/dev/null || true
}

legion_router_read_secret() {
  local name="${1:?secret name required}" service value=""
  service="$(legion_router_secret_service "$name")"

  if [[ "$(uname -s 2>/dev/null || printf unknown)" == "Darwin" ]] && command -v security >/dev/null 2>&1; then
    value="$(security find-generic-password -s "$service" -w 2>/dev/null || true)"
    [[ -n "$value" ]] && { printf '%s' "$value"; return 0; }
  fi

  if command -v secret-tool >/dev/null 2>&1; then
    value="$(secret-tool lookup service legion-router account "$service" 2>/dev/null || true)"
    [[ -n "$value" ]] && { printf '%s' "$value"; return 0; }
  fi

  value="$(legion_router_read_secret_file "$name" 2>/dev/null || true)"
  [[ -n "$value" ]] && printf '%s' "$value"
  return 0
}

legion_router_store_secret() {
  local name="${1:?secret name required}" value="${2:-}" service label
  [[ -n "$value" ]] || return 1
  service="$(legion_router_secret_service "$name")"
  label="$(legion_router_secret_label "$name")"

  if [[ "$(uname -s 2>/dev/null || printf unknown)" == "Darwin" ]] && command -v security >/dev/null 2>&1; then
    security delete-generic-password -s "$service" >/dev/null 2>&1 || true
    if security add-generic-password -s "$service" -a "legion-router" -w "$value" >/dev/null 2>&1; then
      printf 'keychain\n'
      return 0
    fi
  fi

  if command -v secret-tool >/dev/null 2>&1; then
    secret-tool clear service legion-router account "$service" >/dev/null 2>&1 || true
    if printf '%s' "$value" | secret-tool store --label="$label" service legion-router account "$service" >/dev/null 2>&1; then
      printf 'libsecret\n'
      return 0
    fi
  fi

  legion_router_write_secret_file "$name" "$value" || return 1
  printf 'file\n'
}
