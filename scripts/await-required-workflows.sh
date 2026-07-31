#!/usr/bin/env bash
# Fail closed until named push workflows have succeeded for one immutable SHA.
#
# Usage:
#   REPO=owner/repo SHA=<commit> scripts/await-required-workflows.sh validate legion-ci
#
# The caller supplies only *other* workflow names. Refusing the current workflow
# as a requirement prevents an accidental self-wait deadlock.

set -euo pipefail

repo="${REPO:?REPO is required}"
sha="${SHA:?SHA is required}"
timeout_seconds="${CHECK_TIMEOUT_SECONDS:-1500}"
poll_interval_seconds="${CHECK_POLL_INTERVAL_SECONDS:-20}"

if [ "$#" -eq 0 ]; then
    echo "::error::at least one required workflow name is required" >&2
    exit 2
fi
if ! [[ "$timeout_seconds" =~ ^[0-9]+$ ]] || ! [[ "$poll_interval_seconds" =~ ^[0-9]+$ ]]; then
    echo "::error::CHECK_TIMEOUT_SECONDS and CHECK_POLL_INTERVAL_SECONDS must be non-negative integers" >&2
    exit 2
fi

deadline=$((SECONDS + timeout_seconds))

while :; do
    if ! runs="$(gh api "repos/${repo}/actions/runs?head_sha=${sha}&per_page=100" \
        --jq '.workflow_runs
          | map(select(.event == "push"))
          | sort_by(.created_at)
          | reverse
          | .[]
          | [.name, .status, (.conclusion // "-")]
          | @tsv')"; then
        echo "::error::could not read workflow runs for ${sha} — refusing to release" >&2
        exit 1
    fi

    pending=""
    for workflow in "$@"; do
        if [ "${GITHUB_WORKFLOW:-}" = "$workflow" ]; then
            echo "::error::refusing to wait on the current workflow '${workflow}'" >&2
            exit 2
        fi

        line="$(printf '%s\n' "$runs" | awk -F'\t' -v workflow="$workflow" '$1 == workflow { print; exit }')"
        if [ -z "$line" ]; then
            pending="${pending} ${workflow}(not-started)"
            continue
        fi

        status="$(printf '%s' "$line" | cut -f2)"
        conclusion="$(printf '%s' "$line" | cut -f3)"
        if [ "$status" != "completed" ]; then
            pending="${pending} ${workflow}(${status})"
            continue
        fi
        if [ "$conclusion" != "success" ]; then
            echo "::error::${workflow} concluded '${conclusion}' for ${sha} — refusing to release" >&2
            exit 1
        fi

        echo "green: ${workflow}"
    done

    if [ -z "$pending" ]; then
        echo "all required checks green for ${sha}"
        exit 0
    fi
    if [ "$SECONDS" -ge "$deadline" ]; then
        echo "::error::timed out waiting for:${pending} — refusing to release" >&2
        exit 1
    fi

    echo "waiting for:${pending}"
    sleep "$poll_interval_seconds"
done
