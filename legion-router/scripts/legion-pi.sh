#!/usr/bin/env bash
set -euo pipefail
LEGION_ADAPTER_KIND=pi exec "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/legion-pi-hermes.sh" "$@"
