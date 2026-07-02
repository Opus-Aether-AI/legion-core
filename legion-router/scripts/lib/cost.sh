#!/usr/bin/env bash
# cost.sh — compute USD cost for a model from a per-model price table.
#
# Single source of truth for pricing across legion-delegate, the router /ingest
# sink, and opus-agent-infra's cost-summary.sh. Source it, or run it as a CLI.
#
#   source cost.sh
#   cost_for_model "opus" 1000000 500000 0 0              # -> 17.5
#
#   cost.sh claude-sonnet-5 1000000 1000000                # -> 12
#
# Price table resolution order:
#   1. $LEGION_COSTS_FILE (if set)
#   2. <this dir>/../../config/costs.json   (the plugin's bundled table)
# Missing table or unknown model -> $0 (never errors on pricing).

set -euo pipefail

_cost_lib_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
: "${LEGION_COSTS_FILE:=$_cost_lib_dir/../../config/costs.json}"

# cost_for_model <model> <input_tokens> <output_tokens> [cache_read_tokens] [cache_write_tokens]
# Prints USD rounded to 6 decimals (plain number, no $).
cost_for_model() {
  local model="${1:?cost_for_model: model required}"
  local input="${2:-0}" output="${3:-0}" cache_read="${4:-0}" cache_write="${5:-0}"
  local file="$LEGION_COSTS_FILE"
  # Validate every token count is a non-negative integer (safe for any caller, not just delegate):
  # rejects negatives and non-numeric strings (which would also hard-fail jq's --argjson).
  local v
  for v in input output cache_read cache_write; do
    [[ "${!v}" =~ ^[0-9]+$ ]] || printf -v "$v" '%s' 0
  done

  if [[ ! -f "$file" ]]; then
    echo "0"
    return 0
  fi

  jq -n \
    --arg m "$(printf '%s' "$model" | tr '[:upper:]' '[:lower:]')" \
    --argjson in "${input:-0}" \
    --argjson out "${output:-0}" \
    --argjson cr "${cache_read:-0}" \
    --argjson cw "${cache_write:-0}" \
    --slurpfile cfg "$file" '
      ($cfg[0]) as $c
      | ( [ $c.models[] | select(.match as $mm | $m | contains($mm)) ] | first ) as $row
      | ( $row // $c.default ) as $p
      | ( ($in  / 1000000) * ($p.input       // 0)
        + ($out / 1000000) * ($p.output      // 0)
        + ($cr  / 1000000) * ($p.cache_read  // 0)
        + ($cw  / 1000000) * ($p.cache_write // 0) )
      | (. * 1000000 | round) / 1000000
    '
}

# Run as CLI when executed directly (not sourced).
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  cost_for_model "$@"
fi
