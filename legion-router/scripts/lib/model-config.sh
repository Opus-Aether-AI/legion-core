#!/usr/bin/env bash
# Resolve active default model IDs from legion-router/config/models.toml.

_legion_model_config_lib_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_legion_model_config_route_bin="${LEGION_ROUTE_BIN:-$_legion_model_config_lib_dir/../legion-route.py}"

legion_model_ref() {
  local ref="$1"
  python3 "$_legion_model_config_route_bin" --model-ref "$ref"
}
