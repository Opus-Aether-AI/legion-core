#!/usr/bin/env bash
# vendor.sh — repackage upstream `git-subdir` plugins into local `vendored/<name>/`
#
# Why this exists
# ---------------
# Claude Code's plugin loader treats plugins differently based on how they're
# sourced. Plugins with `"source": "./<dir>"` + a semver `"version"` surface to
# the Skill registry as `<plugin>:<skill>`. Plugins with `"source": {git-subdir}`
# + `"version": "vendored"` install successfully but a large fraction never
# reach the Skill registry. See GitHub issue #18.
#
# Fix: vendor the upstream content into the marketplace repo so every plugin
# uses the same source path + semver shape that the loader understands.
#
# What this does
# --------------
# For every plugin in `.claude-plugin/marketplace.json` whose `source` is an
# object of type `git-subdir`, this script:
#
#   1. Clones the upstream `url` at the pinned `sha` into a local cache
#      (`/tmp/.vendor-cache/<url-hash>`).
#   2. Copies the `path` subdirectory into `vendored/<name>/` (rsync,
#      excluding `.git`).
#   3. Rewrites the plugin entry in marketplace.json:
#        - `source`   : object  →  `"./vendored/<name>"`
#        - `version`  : "vendored" → "0.1.0"  (or bump if already vendored)
#        - `upstream` : preserves the upstream pin (url, path, ref, sha) for
#                       the sync-vendored.yml workflow.
#
# Modes
# -----
#   ./scripts/vendor.sh           # vendor at pinned SHAs (idempotent)
#   ./scripts/vendor.sh bump      # ls-remote each upstream, write latest SHA
#                                 # into marketplace.json (does NOT vendor).
#   ./scripts/vendor.sh bump-and-vendor
#                                 # bump + vendor in one pass.
#
# Requires: jq, git, rsync, sha1sum (or shasum -a 1).
set -euo pipefail

MARKETPLACE_JSON=".claude-plugin/marketplace.json"
VENDORED_DIR="vendored"
CACHE_DIR="${VENDOR_CACHE_DIR:-/tmp/.vendor-cache}"
SEMVER_DEFAULT="0.1.0"

# Helper libs live alongside this script.
_VENDOR_SELF="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NORMALIZE_AWK="$_VENDOR_SELF/lib/normalize-skill-description.awk"

# ── Output helpers ──────────────────────────────────────────────────
red()    { printf '\033[0;31m%s\033[0m\n' "$*" >&2; }
green()  { printf '\033[0;32m%s\033[0m\n' "$*"; }
yellow() { printf '\033[0;33m%s\033[0m\n' "$*"; }
dim()    { printf '\033[0;90m%s\033[0m\n' "$*"; }
bold()   { printf '\033[1m%s\033[0m\n' "$*"; }

# ── Preflight ───────────────────────────────────────────────────────
for cmd in jq git rsync; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
        red "$cmd required. Install: brew install $cmd"
        exit 1
    fi
done

if [ ! -f "$MARKETPLACE_JSON" ]; then
    red "Run from repo root. Expected $MARKETPLACE_JSON to exist."
    exit 1
fi

# Portable sha1 (macOS lacks sha1sum)
sha1() {
    if command -v sha1sum >/dev/null 2>&1; then
        printf '%s' "$1" | sha1sum | awk '{print $1}'
    else
        printf '%s' "$1" | shasum -a 1 | awk '{print $1}'
    fi
}

mkdir -p "$CACHE_DIR"

# ── Clone upstream into cache (once per URL) ────────────────────────
# Returns the path on stdout.
clone_upstream() {
    local url="$1"
    local hash; hash=$(sha1 "$url")
    local dir="$CACHE_DIR/$hash"
    if [ ! -d "$dir/.git" ]; then
        dim "  cloning $url" >&2
        git clone --quiet --filter=blob:none "$url" "$dir" >&2
    else
        # Fresh fetch so we can check out any SHA the marketplace pins.
        git -C "$dir" fetch --quiet --tags origin
    fi
    printf '%s' "$dir"
}

# ── Vendor one plugin entry ─────────────────────────────────────────
vendor_one() {
    local name="$1"
    local url="$2"
    local subpath="$3"
    local ref="$4"
    local sha="$5"

    local clone; clone=$(clone_upstream "$url")
    # Checkout pinned SHA. Use --detach to avoid touching local branches.
    if ! git -C "$clone" checkout --quiet --detach "$sha" 2>/dev/null; then
        # SHA may not be reachable yet — try fetching it explicitly.
        git -C "$clone" fetch --quiet origin "$sha" >/dev/null 2>&1 || true
        git -C "$clone" checkout --quiet --detach "$sha"
    fi

    local src="$clone/$subpath"
    if [ ! -d "$src" ]; then
        red "  ✘ $name: upstream subpath $subpath does not exist at $sha"
        return 1
    fi

    local dest="$VENDORED_DIR/$name"
    rm -rf "$dest"
    mkdir -p "$dest"
    rsync -a --delete --exclude='.git' "$src/" "$dest/"

    # Normalize SKILL.md casing. Some upstreams (e.g. better-auth/skills) ship
    # `SKILL.MD` with an uppercase extension. Claude Code's loader and our CI
    # both look for the exact case `SKILL.md`, so any plugin shipped with the
    # uppercase form is invisible to discovery on case-sensitive filesystems
    # (Linux/CI) and silently passes on macOS. Rename in place.
    if [ -f "$dest/SKILL.MD" ] && [ ! -f "$dest/SKILL.md" ]; then
        mv "$dest/SKILL.MD" "$dest/SKILL.md.tmp" && mv "$dest/SKILL.md.tmp" "$dest/SKILL.md"
        yellow "    (normalized SKILL.MD → SKILL.md)"
    fi

    # Flatten any YAML block-scalar `description:` (`>` / `|`) in vendored
    # SKILL.md files to a single quoted line. Line-based frontmatter readers
    # (the Cursor bridge, some skill loaders) otherwise capture just ">"/"|" and
    # the real description is lost — the skill shows blank + stops auto-triggering.
    # Recurse: some plugins (e.g. vercel-plugin) nest skills under skills/<name>/.
    if [ -f "$NORMALIZE_AWK" ]; then
        while IFS= read -r skill; do
            local tmp; tmp=$(mktemp)
            if awk -f "$NORMALIZE_AWK" "$skill" > "$tmp" && ! cmp -s "$skill" "$tmp"; then
                mv "$tmp" "$skill"
                yellow "    (flattened block-scalar description in ${skill#"$dest/"})"
            else
                rm -f "$tmp"
            fi
        done < <(find "$dest" -name SKILL.md 2>/dev/null)
    fi

    # Patch missing `version` in an upstream .claude-plugin/plugin.json.
    # Some upstreams (notably anthropics/claude-plugins-official) ship the
    # plugin.json without a `version` field — they set it from release
    # tooling outside the repo. Our validate-plugins CI requires the field.
    # Inject the marketplace-level semver so the manifest is self-contained.
    local manifest="$dest/.claude-plugin/plugin.json"
    if [ -f "$manifest" ]; then
        if ! jq -e '.version' "$manifest" > /dev/null 2>&1; then
            local mp_ver; mp_ver=$(jq -r --arg n "$name" \
                '.plugins[] | select(.name == $n) | .version // "0.1.0"' \
                "$MARKETPLACE_JSON")
            local tmp; tmp=$(mktemp)
            jq --arg v "$mp_ver" '.version = $v' "$manifest" > "$tmp"
            mv "$tmp" "$manifest"
            yellow "    (patched plugin.json with version=$mp_ver)"
        fi
        # Same for missing `description` — fall back to marketplace.json's
        # description so the upstream doesn't need to ship the field either.
        if ! jq -e '.description' "$manifest" > /dev/null 2>&1; then
            local mp_desc; mp_desc=$(jq -r --arg n "$name" \
                '.plugins[] | select(.name == $n) | .description // ""' \
                "$MARKETPLACE_JSON")
            local tmp; tmp=$(mktemp)
            jq --arg d "$mp_desc" '.description = $d' "$manifest" > "$tmp"
            mv "$tmp" "$manifest"
            yellow "    (patched plugin.json with description from marketplace)"
        fi
    fi

    green "  ✔ $name  (from ${url##*/}#${sha:0:8} @ $subpath)"
}

# ── Rewrite marketplace.json entry ──────────────────────────────────
# Switches `source` to "./vendored/<name>", bumps version to semver,
# adds `upstream` metadata so sync-vendored.yml can re-resolve SHAs.
rewrite_entry() {
    local name="$1"
    local url="$2"
    local subpath="$3"
    local ref="$4"
    local sha="$5"
    local version="$6"

    local tmp; tmp=$(mktemp)
    jq --arg name "$name" \
       --arg src "./$VENDORED_DIR/$name" \
       --arg ver "$version" \
       --arg url "$url" \
       --arg path "$subpath" \
       --arg ref "$ref" \
       --arg sha "$sha" \
       '
       .plugins |= map(
         if .name == $name then
           . + {
             source: $src,
             version: $ver,
             upstream: { url: $url, path: $path, ref: $ref, sha: $sha }
           }
         else . end
       )
       ' "$MARKETPLACE_JSON" > "$tmp"
    mv "$tmp" "$MARKETPLACE_JSON"
}

# ── Bump SHAs to latest on ref (does not vendor) ───────────────────
do_bump() {
    bold "Bumping vendored SHAs to latest on their pinned ref..."
    local entries; entries=$(jq -c '
        .plugins[]
        | select(.source | type == "object")
        | select(.source.source == "git-subdir")
        | {name, url: .source.url, path: .source.path, ref: .source.ref, sha: .source.sha}
    ' "$MARKETPLACE_JSON")
    # Also handle already-vendored entries that store upstream pin in `.upstream`.
    local entries2; entries2=$(jq -c '
        .plugins[]
        | select(.upstream != null)
        | {name, url: .upstream.url, path: .upstream.path, ref: .upstream.ref, sha: .upstream.sha}
    ' "$MARKETPLACE_JSON")

    local all_entries; all_entries=$(printf '%s\n%s' "$entries" "$entries2" | awk 'NF && !seen[$0]++')

    local bumped=0
    while IFS= read -r entry; do
        [ -z "$entry" ] && continue
        local name; name=$(echo "$entry" | jq -r .name)
        local url;  url=$(echo "$entry"  | jq -r .url)
        local ref;  ref=$(echo "$entry"  | jq -r .ref)
        local old;  old=$(echo "$entry"  | jq -r .sha)
        local new;  new=$(git ls-remote "$url" "$ref" 2>/dev/null | awk 'NR==1 {print $1}')
        if [ -z "$new" ]; then
            yellow "  ⚠ $name: could not resolve $url@$ref — leaving sha=${old:0:8}"
            continue
        fi
        if [ "$new" = "$old" ]; then
            dim "  ↺ $name: ${old:0:8} (unchanged)"
            continue
        fi
        green "  ↑ $name: ${old:0:8} → ${new:0:8}"
        local tmp; tmp=$(mktemp)
        jq --arg name "$name" --arg sha "$new" '
          .plugins |= map(
            if .name == $name then
              # Update both source.sha (for not-yet-vendored entries) and upstream.sha (for vendored).
              if .source | type == "object" then .source.sha = $sha else . end
              | if .upstream != null then .upstream.sha = $sha else . end
            else . end
          )
        ' "$MARKETPLACE_JSON" > "$tmp"
        mv "$tmp" "$MARKETPLACE_JSON"
        bumped=$((bumped + 1))
    done <<< "$all_entries"
    bold "Bumped $bumped entries."
}

# ── Vendor every git-subdir entry into vendored/<name>/ ─────────────
do_vendor() {
    bold "Vendoring upstreams into ./$VENDORED_DIR/..."
    mkdir -p "$VENDORED_DIR"

    # Iterate marketplace.json entries that still use object source (first
    # migration) AND those already migrated (re-vendor at pinned SHA).
    local entries; entries=$(jq -c '
        .plugins[]
        | select((.source | type == "object") or (.upstream != null))
        | {
            name,
            url:  (if .upstream then .upstream.url  else .source.url  end),
            path: (if .upstream then .upstream.path else .source.path end),
            ref:  (if .upstream then .upstream.ref  else .source.ref  end),
            sha:  (if .upstream then .upstream.sha  else .source.sha  end),
            already_migrated: (.upstream != null)
          }
    ' "$MARKETPLACE_JSON")

    local count=0 failed=0
    while IFS= read -r entry; do
        [ -z "$entry" ] && continue
        local name url subpath ref sha already
        name=$(echo "$entry"    | jq -r .name)
        url=$(echo "$entry"     | jq -r .url)
        subpath=$(echo "$entry" | jq -r .path)
        ref=$(echo "$entry"     | jq -r .ref)
        sha=$(echo "$entry"     | jq -r .sha)
        already=$(echo "$entry" | jq -r .already_migrated)

        if vendor_one "$name" "$url" "$subpath" "$ref" "$sha"; then
            # Preserve existing version if already migrated; otherwise use default.
            local version="$SEMVER_DEFAULT"
            if [ "$already" = "true" ]; then
                version=$(jq -r --arg name "$name" \
                  '.plugins[] | select(.name == $name) | .version' "$MARKETPLACE_JSON")
            fi
            rewrite_entry "$name" "$url" "$subpath" "$ref" "$sha" "$version"
            count=$((count + 1))
        else
            failed=$((failed + 1))
        fi
    done <<< "$entries"

    bold ""
    bold "━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    green "  $count plugins vendored"
    [ "$failed" -gt 0 ] && red "  $failed failed"
}

# ── Mode dispatch ──────────────────────────────────────────────────
MODE="${1:-vendor}"
case "$MODE" in
    bump)              do_bump ;;
    vendor)            do_vendor ;;
    bump-and-vendor)   do_bump; do_vendor ;;
    -h|--help|help)    sed -n '/^# vendor.sh/,/^set -euo pipefail/p' "$0" | sed 's/^# \?//'; exit 0 ;;
    *) red "Unknown mode: $MODE  (try: vendor | bump | bump-and-vendor)"; exit 1 ;;
esac

bold "Done."
