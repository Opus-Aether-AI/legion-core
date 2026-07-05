#!/usr/bin/env bash
# Run the Legion python unit tests with the locked dev environment when uv is
# available, falling back to an already-installed pytest for minimal systems.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT"
if command -v uv >/dev/null 2>&1 && [[ -f uv.lock ]]; then
  exec uv run --locked pytest -q "$@"
elif python3 -c 'import pytest' 2>/dev/null; then
  exec python3 -m pytest -q "$@"
else
  echo "pytest unavailable (need uv with uv.lock or a pytest install)" >&2
  exit 1
fi
