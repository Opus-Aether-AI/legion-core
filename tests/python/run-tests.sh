#!/usr/bin/env bash
# Run the Legion python unit tests (legion-aggregate, legion-otel-export).
set -euo pipefail
cd "$(dirname "$0")"
if command -v uvx >/dev/null 2>&1; then
  exec uvx --with pytest pytest -q "$@"
elif python3 -c 'import pytest' 2>/dev/null; then
  exec python3 -m pytest -q "$@"
else
  echo "pytest unavailable (need uvx or a pytest install)" >&2
  exit 1
fi
