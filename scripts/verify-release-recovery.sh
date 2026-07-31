#!/usr/bin/env bash
# Verify an immutable historical release using recovery controls from the
# current workflow revision. The release tree is data only: none of its helper
# scripts are executed by this verifier.

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
RELEASE_TAG="${1:-}"
RELEASE_DIR="${2:-}"

if [ -z "$RELEASE_TAG" ] || [ -z "$RELEASE_DIR" ] || [ -z "${GITHUB_OUTPUT:-}" ]; then
    printf 'usage: GITHUB_OUTPUT=<path> %s <vSemVer-tag> <release-directory>\n' "$0" >&2
    exit 2
fi

# This is deliberately the install.sh beside this helper, not the installer in
# RELEASE_DIR. Older releases such as v0.19.0 do not expose this validation mode.
bash "$SCRIPT_DIR/install.sh" --validate-release-tag="$RELEASE_TAG"

if [ ! -d "$RELEASE_DIR/.git" ]; then
    printf 'release recovery: %s is not a Git checkout\n' "$RELEASE_DIR" >&2
    exit 2
fi

tag_ref="refs/tags/${RELEASE_TAG}"
if ! git -C "$RELEASE_DIR" show-ref --tags --verify --quiet "$tag_ref"; then
    printf 'release recovery: exact tag %s is not present\n' "$RELEASE_TAG" >&2
    exit 2
fi

tag_sha="$(git -C "$RELEASE_DIR" rev-parse --verify "${tag_ref}^{commit}")"
head_sha="$(git -C "$RELEASE_DIR" rev-parse HEAD)"
if [ "$tag_sha" != "$head_sha" ]; then
    printf 'release recovery: %s resolves to %s, not checked-out %s\n' \
        "$RELEASE_TAG" "$tag_sha" "$head_sha" >&2
    exit 2
fi

tag_version="${RELEASE_TAG#v}"
package_name="$(jq -er '.name | select(type == "string" and length > 0)' "$RELEASE_DIR/package.json")"
package_version="$(jq -er '.version | select(type == "string" and length > 0)' "$RELEASE_DIR/package.json")"
marketplace_version="$(jq -er '.version | select(type == "string" and length > 0)' "$RELEASE_DIR/.claude-plugin/marketplace.json")"
if [ "$tag_version" != "$package_version" ] || [ "$tag_version" != "$marketplace_version" ]; then
    printf 'release recovery: %s must match package.json (%s) and marketplace.json (%s)\n' \
        "$RELEASE_TAG" "$package_version" "$marketplace_version" >&2
    exit 2
fi

{
    printf 'sha=%s\n' "$head_sha"
    printf 'package=%s\n' "$package_name"
    printf 'version=%s\n' "$tag_version"
} >> "$GITHUB_OUTPUT"

printf '%s resolves to %s; versions are in sync\n' "$RELEASE_TAG" "$head_sha"
