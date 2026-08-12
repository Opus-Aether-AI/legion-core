#!/usr/bin/env bash
set -euo pipefail
LEGION_PRIMARY_SETUP_KIND=hermes exec "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/legion-primary-setup.sh" "$@"
