#!/usr/bin/env bash
set -euo pipefail

# Find the immutable Release Please merge commit for the version currently in
# the manifest. This lets a later main push repair a GitHub Release that the
# default Actions integration was not permitted to create.

repo="${1:-$PWD}"
repo="$(cd "$repo" >/dev/null 2>&1 && pwd)"
output="${GITHUB_OUTPUT:-}"
gh_repo="${GH_REPO:-${GITHUB_REPOSITORY:-}}"
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"

if [ -z "$output" ] || [ -z "$gh_repo" ]; then
    echo "usage: GITHUB_OUTPUT=<path> GH_REPO=<owner/repo> $0 [repo]" >&2
    exit 2
fi
if [ ! -d "$repo/.git" ] && ! git -C "$repo" rev-parse --git-dir >/dev/null 2>&1; then
    echo "::error::$repo is not a Git checkout" >&2
    exit 2
fi

package_version="$(jq -er '.version | select(type == "string" and length > 0)' "$repo/package.json")"
manifest_version="$(jq -er '.["."] | select(type == "string" and length > 0)' "$repo/.release-please-manifest.json")"
if [ "$package_version" != "$manifest_version" ]; then
    echo "::error::package.json ($package_version) and release manifest ($manifest_version) differ" >&2
    exit 1
fi

tag="v$package_version"
bash "$script_dir/install.sh" --validate-release-tag="$tag" >/dev/null
expected_title="chore(main): release $package_version"
release_sha=""
while IFS=$'\t' read -r sha title; do
    # GitHub's squash merge appends the PR number to the configured PR title.
    # Accept only that exact suffix; arbitrary subjects must not select a
    # release commit merely because they share the expected prefix.
    normalized_title="$title"
    if [[ "$title" =~ \ \(#[0-9]+\)$ ]]; then
        normalized_title="${title%"${BASH_REMATCH[0]}"}"
    fi
    if [ "$normalized_title" = "$expected_title" ]; then
        release_sha="$sha"
        break
    fi
done < <(git -C "$repo" log --first-parent --format='%H%x09%s')

if [ -z "$release_sha" ]; then
    echo "::error::no first-parent commit has exact title: $expected_title" >&2
    exit 1
fi
git -C "$repo" merge-base --is-ancestor "$release_sha" HEAD || {
    echo "::error::release commit $release_sha is not an ancestor of HEAD" >&2
    exit 1
}

release_package="$(git -C "$repo" show "$release_sha:package.json" | jq -er '.version')"
release_manifest="$(git -C "$repo" show "$release_sha:.release-please-manifest.json" | jq -er '.["."]')"
if [ "$release_package" != "$package_version" ] || [ "$release_manifest" != "$package_version" ]; then
    echo "::error::release commit $release_sha does not contain synchronized version $package_version" >&2
    exit 1
fi

tag_exists=false
if git -C "$repo" show-ref --verify --quiet "refs/tags/$tag"; then
    tag_sha="$(git -C "$repo" rev-parse --verify "refs/tags/$tag^{commit}")"
    if [ "$tag_sha" != "$release_sha" ]; then
        echo "::error::$tag resolves to $tag_sha, expected release commit $release_sha" >&2
        exit 1
    fi
    tag_exists=true
fi

{
    printf 'version=%s\n' "$package_version"
    printf 'tag_name=%s\n' "$tag"
} >> "$output"

if gh release view "$tag" --repo "$gh_repo" >/dev/null 2>&1; then
    if [ "$tag_exists" != true ]; then
        echo "::error::$tag has a GitHub Release but no fetched tag ref" >&2
        exit 1
    fi
    # skip-github-release leaves Release Please's PR labeled `autorelease:
    # pending` when the release bot creates the GitHub Release. Release Please
    # treats that stale label as an untagged merged release and silently aborts
    # every later release. Reconcile only the exact title + merge commit pair.
    pending_prs="$(
        gh pr list --repo "$gh_repo" --state merged \
            --label 'autorelease: pending' --search "\"$expected_title\" in:title" \
            --limit 20 --json number,title,mergeCommit
    )" || {
        echo "::error::could not inspect pending Release Please labels" >&2
        exit 1
    }
    release_pr="$(
        jq -r --arg title "$expected_title" --arg sha "$release_sha" \
            '[.[] | select(.title == $title and .mergeCommit.oid == $sha) | .number] | first // empty' \
            <<<"$pending_prs"
    )"
    if [ -n "$release_pr" ]; then
        # gh implements add/remove as separate mutations. Add first so a
        # partial failure leaves `pending` discoverable and the next run can
        # retry safely; removing first could strand the PR with neither label.
        gh pr edit "$release_pr" --repo "$gh_repo" --add-label 'autorelease: tagged'
        gh pr edit "$release_pr" --repo "$gh_repo" --remove-label 'autorelease: pending'
        echo "reconciled Release PR #$release_pr to autorelease: tagged"
    fi
    printf 'pending=false\n' >> "$output"
    echo "$tag already has a GitHub Release"
    exit 0
fi

{
    printf 'pending=true\n'
    printf 'release_sha=%s\n' "$release_sha"
    printf 'tag_exists=%s\n' "$tag_exists"
} >> "$output"
echo "pending GitHub Release: $tag at $release_sha"
