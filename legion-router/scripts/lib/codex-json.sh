#!/usr/bin/env bash
# codex-json.sh — parse `codex exec --json` JSONL event streams.
#
# Pinned to the codex-cli 0.139.x event shape:
#   {"type":"thread.started","thread_id":"..."}
#   {"type":"turn.started"}
#   {"type":"item.completed","item":{"id":"item_0","type":"agent_message","text":"..."}}
#   {"type":"turn.completed","usage":{"input_tokens":N,"cached_input_tokens":N,
#                                     "output_tokens":N,"reasoning_output_tokens":N}}
#
# This file is the SINGLE point that knows codex's event/usage field names; a
# codex-cli upgrade that changes them is fixed here and re-validated by the
# fixture-driven tests. Tolerates interleaved non-JSON lines.
#
# Source it, or run as a CLI:
#   codex-json.sh thread-id     <file|->
#   codex-json.sh last-message  <file|->
#   codex-json.sh usage         <file|->   # -> {input_tokens,cached_input_tokens,output_tokens,reasoning_output_tokens}

set -euo pipefail

# Emit only valid JSON objects from a JSONL source ($1 = file, "-" or empty = stdin).
_cj_stream() {
  local src="${1:-/dev/stdin}"
  [[ -z "$src" || "$src" == "-" ]] && src=/dev/stdin
  jq -R 'fromjson? // empty' "$src"
}

codex_thread_id() {
  _cj_stream "${1:-}" | jq -rs 'map(select(.type=="thread.started"))[0].thread_id // ""'
}

codex_last_message() {
  _cj_stream "${1:-}" | jq -rs '
    [ .[] | select(.type=="item.completed" and .item.type=="agent_message") | .item.text ]
    | last // ""'
}

# Sum usage across all turn.completed events (a delegated task may take many turns).
codex_usage() {
  _cj_stream "${1:-}" | jq -s '
    [ .[] | select(.type=="turn.completed") | .usage ]
    | {
        input_tokens:            (map(.input_tokens            // 0) | add // 0),
        cached_input_tokens:     (map(.cached_input_tokens     // 0) | add // 0),
        output_tokens:           (map(.output_tokens           // 0) | add // 0),
        reasoning_output_tokens: (map(.reasoning_output_tokens // 0) | add // 0)
      }'
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  cmd="${1:-}"
  shift || true
  case "$cmd" in
    thread-id)    codex_thread_id "${1:-}" ;;
    last-message) codex_last_message "${1:-}" ;;
    usage)        codex_usage "${1:-}" ;;
    *) echo "usage: codex-json.sh {thread-id|last-message|usage} [file|-]" >&2; exit 2 ;;
  esac
fi
