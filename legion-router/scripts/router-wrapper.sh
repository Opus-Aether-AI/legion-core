#!/usr/bin/env bash
# Wrapper for the Legion Router — resolves secrets, then execs bun on router.ts.
# Called by launchd or foreground `legion-router dev`. Secrets are OPTIONAL (the
# router meters without them).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BUN_PATH="${BUN_PATH:-$(command -v bun 2>/dev/null || echo "$HOME/.bun/bin/bun")}"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/router-secrets.sh"

export ANTHROPIC_API_KEY="${ANTHROPIC_API_KEY:-$(legion_router_read_secret anthropic)}"
export MINIMAX_AUTH_TOKEN="${MINIMAX_AUTH_TOKEN:-$(legion_router_read_secret minimax)}"

exec "$BUN_PATH" run "$SCRIPT_DIR/router.ts"
