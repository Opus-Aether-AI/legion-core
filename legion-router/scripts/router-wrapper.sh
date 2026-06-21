#!/usr/bin/env bash
# Wrapper for the Legion Router — resolves secrets, then execs bun on router.ts.
# Called by launchd. Secrets are OPTIONAL (the router meters without them).
#
# Resolution order per secret: env var -> legion-* Keychain item -> legacy
# legion-* Keychain item (reuses a sibling model-router install's creds).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BUN_PATH="${BUN_PATH:-$(command -v bun 2>/dev/null || echo "$HOME/.bun/bin/bun")}"

# Keychain lookup — macOS only. With `security` absent (e.g. a Linux foreground
# run) this degrades to empty so the router still starts as a pure meter.
_kc() { command -v security >/dev/null 2>&1 && security find-generic-password -s "$1" -w 2>/dev/null || true; }

export ANTHROPIC_API_KEY="${ANTHROPIC_API_KEY:-$(_kc legion-anthropic)}"
export MINIMAX_AUTH_TOKEN="${MINIMAX_AUTH_TOKEN:-$(_kc legion-minimax)}"

exec "$BUN_PATH" run "$SCRIPT_DIR/router.ts"
