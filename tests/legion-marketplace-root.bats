#!/usr/bin/env bats
# legion-marketplace-root — resolve the consumer marketplace root, vendor-aware.
# Self-contained: builds synthetic standalone / vendored layouts in a tmpdir.

setup() {
  ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  HELPER="$ROOT/legion-setup/scripts/legion-marketplace-root.sh"
  # shellcheck disable=SC1090
  source "$HELPER"
  unset MARKETPLACE_ROOT LEGION_MARKETPLACE_ROOT
}

# Real path of a dir (BATS tmpdir may be a symlink on macOS).
_real() { (cd "$1" && pwd); }

@test "vendored: resolves the CONSUMER marketplace, not legion-core's own" {
  local consumer="$BATS_TEST_TMPDIR/consumer"
  mkdir -p "$consumer/.claude-plugin"
  echo '{}' > "$consumer/.claude-plugin/marketplace.json"
  # legion-core vendored under the consumer, with its OWN marketplace.json.
  local here="$consumer/vendored/legion-core/legion-setup/scripts"
  mkdir -p "$here" "$consumer/vendored/legion-core/.claude-plugin"
  echo '{}' > "$consumer/vendored/legion-core/.claude-plugin/marketplace.json"

  run legion_resolve_marketplace_root "$here"
  [ "$status" -eq 0 ]
  [ "$output" = "$(_real "$consumer")" ]
}

@test "standalone: resolves legion-core's own root" {
  local core="$BATS_TEST_TMPDIR/legion-core"
  mkdir -p "$core/.claude-plugin" "$core/legion-setup/scripts"
  echo '{}' > "$core/.claude-plugin/marketplace.json"

  run legion_resolve_marketplace_root "$core/legion-setup/scripts"
  [ "$status" -eq 0 ]
  [ "$output" = "$(_real "$core")" ]
}

@test "MARKETPLACE_ROOT override wins over the walk" {
  local override="$BATS_TEST_TMPDIR/override"; mkdir -p "$override"
  MARKETPLACE_ROOT="$override" run legion_resolve_marketplace_root "$BATS_TEST_TMPDIR"
  [ "$status" -eq 0 ]
  [ "$output" = "$(_real "$override")" ]
}
