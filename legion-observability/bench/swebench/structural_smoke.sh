#!/usr/bin/env bash
# structural_smoke.sh — verify SWE-bench instance data is coherent WITHOUT Docker.
#
# For each instance in a manifest (see fetch_instances.py): fetch the repo at
# base_commit (single-SHA depth-1), apply the test_patch, then check that the
# gold solution `patch` applies cleanly. This proves the instance + gold oracle
# are structurally valid (the data is wired correctly). It does NOT run the tests
# — executing FAIL_TO_PASS/PASS_TO_PASS needs the per-repo environment, which is
# what the Docker eval harness provides (see README.md).
#
#   bash structural_smoke.sh <manifest.json> [workdir]
set -euo pipefail

manifest="${1:?usage: structural_smoke.sh <manifest.json> [workdir]}"
workdir="${2:-$(mktemp -d "${TMPDIR:-/tmp}/swe-smoke.XXXXXX")}"
mkdir -p "$workdir"

count="$(jq '.instances | length' "$manifest")"
echo "structural smoke over $count instance(s) → $workdir"
pass=0
for i in $(seq 0 $(( count - 1 ))); do
  inst="$(jq -r ".instances[$i].instance_id" "$manifest")"
  repo="$(jq -r ".instances[$i].repo" "$manifest")"
  base="$(jq -r ".instances[$i].base_commit" "$manifest")"
  # Sanitize the instance id to a safe basename before it touches a path used
  # with rm -rf (a '../' in a manifest must not escape the workdir).
  safe="$(printf '%s' "$inst" | tr -cd 'A-Za-z0-9._-')"
  [ -n "$safe" ] || safe="instance-$i"
  dir="$workdir/$safe"
  rm -rf "$dir" 2>/dev/null || true
  mkdir -p "$dir"
  (
    cd "$dir"
    git init -q
    git remote add origin "https://github.com/$repo"
    if ! git fetch --depth 1 origin "$base" -q 2>/dev/null; then
      echo "  ✗ $inst: fetch $base failed"; exit 1
    fi
    git checkout -q FETCH_HEAD
    jq -r ".instances[$i].test_patch" "$manifest" > test.diff
    jq -r ".instances[$i].patch" "$manifest" > gold.diff
    git apply test.diff 2>/dev/null || { echo "  ✗ $inst: test_patch failed"; exit 1; }
    if git apply --check gold.diff 2>/dev/null; then
      echo "  ✓ $inst ($repo): test_patch applied, gold patch applies cleanly"
    else
      echo "  ✗ $inst: gold patch does not apply"; exit 1
    fi
  ) && pass=$(( pass + 1 )) || true
done
echo "structural smoke: $pass/$count instances coherent"
[ "$pass" -eq "$count" ]
