#!/usr/bin/env bash
set -euo pipefail

if [ "$#" -ne 1 ]; then
  echo "usage: validate-conventional-title.sh <title>" >&2
  exit 2
fi

title="$1"
pattern='^(feat|fix|perf|refactor|docs|revert|chore|style|test|ci|build)(\([[:alnum:]./_-]+\))?!?: [^[:space:]].*$'

if [[ "$title" =~ $pattern ]]; then
  exit 0
fi

cat >&2 <<'EOF'
Title must use a Release Please-compatible Conventional Commit:
  <type>[optional scope][!]: <summary>

Allowed types: feat, fix, perf, refactor, docs, revert, chore, style, test, ci, build
Example: feat(setup): make Legion the default
EOF
exit 1
