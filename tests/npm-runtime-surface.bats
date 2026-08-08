#!/usr/bin/env bats
# The npm tarball is a distinct runtime surface: npm creates .bin symlinks that
# must resolve wrappers from their real package locations rather than a source
# checkout or a global install.

setup() {
  ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  PACK_DIR="$BATS_TEST_TMPDIR/pack"
  CONSUMER="$BATS_TEST_TMPDIR/consumer"
  EXTRACTED="$BATS_TEST_TMPDIR/extracted"
  NPM_CACHE="$BATS_TEST_TMPDIR/npm-cache"
  PACK_JSON="$BATS_TEST_TMPDIR/npm-pack.json"
  mkdir -p "$PACK_DIR" "$CONSUMER" "$EXTRACTED" "$NPM_CACHE"
}

@test "npm package ships its runtime surface and works through npm bin shims offline" {
  # npm can emit update notices on stderr; Bats combines both streams in
  # $output, which would corrupt otherwise-valid --json output. Keep the JSON
  # in its own file and use `run` only for the command status.
  run bash -c 'cd "$1" && npm pack --cache "$2" --json --pack-destination "$3" >"$4"' -- \
    "$ROOT" "$NPM_CACHE" "$PACK_DIR" "$PACK_JSON"
  [ "$status" -eq 0 ]

  local tarball
  tarball="$PACK_DIR/$(jq -r '.[0].filename' "$PACK_JSON")"
  [ -f "$tarball" ]
  tar -xzf "$tarball" -C "$EXTRACTED"

  local required
  for required in \
    "legion-opencode-mode/SKILL.md" \
    "legion-opencode-mode/.claude-plugin/plugin.json" \
    "legion-hermes-mode/SKILL.md" \
    "legion-hermes-mode/.claude-plugin/plugin.json"; do
    [ -f "$EXTRACTED/package/$required" ]
  done

  local name target
  while IFS=$'\t' read -r name target; do
    [ -f "$EXTRACTED/package/$target" ]
    [ -x "$EXTRACTED/package/$target" ]
  done < <(jq -r '.bin | to_entries[] | "\(.key)\t\(.value)"' "$ROOT/package.json")

  run npm --prefix "$CONSUMER" install --cache "$NPM_CACHE" --ignore-scripts --offline --no-audit --no-fund --omit=optional "$tarball"
  [ "$status" -eq 0 ]

  local command
  for command in legion-state legion-context-profile legion-learn legion-improve legion-session-learn legion-opencode legion-opencode-setup; do
    run "$CONSUMER/node_modules/.bin/$command" --help
    [ "$status" -eq 0 ]
  done

  [ "$(jq -r '.optionalDependencies["@ai-hero/sandcastle"]' "$ROOT/package.json")" = "0.12.0" ]
}
