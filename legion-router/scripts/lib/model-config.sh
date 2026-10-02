#!/usr/bin/env bash
# Resolve active default model IDs from legion-router/config/models.toml.

_legion_model_config_lib_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_legion_model_config_route_bin="${LEGION_ROUTE_BIN:-$_legion_model_config_lib_dir/../legion-route.py}"

legion_model_ref() {
  local ref="$1"
  python3 "$_legion_model_config_route_bin" --model-ref "$ref"
}

# A catalog role is a routing name, not a provider model ID. Resolve roles
# owned by this executor before either admission or CLI launch so the concrete
# model checked by preflight is the one the provider actually receives.
legion_provider_model() {
  local executor="$1" requested="$2" resolved=""
  if [[ "$requested" == "${executor}_"* ]]; then
    resolved="$(legion_model_ref "$requested" 2>/dev/null)" || resolved=""
  fi
  printf '%s' "${resolved:-$requested}"
}
