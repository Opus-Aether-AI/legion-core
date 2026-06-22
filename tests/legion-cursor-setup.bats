#!/usr/bin/env bats
# legion-cursor-setup — wire Legion MCPs, commands, agents, and skill-loader into
# Cursor Agent without touching the user's real ~/.cursor.

setup() {
  ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  SETUP_SH="$ROOT/legion-setup/scripts/legion-cursor-setup.sh"
  MERGE_PY="$ROOT/legion-setup/scripts/legion-cursor-mcp-merge.py"

  export HOME="$BATS_TEST_TMPDIR/home"
  export AGENTS_HOME="$BATS_TEST_TMPDIR/agents"
  export CURSOR_MCP_CONFIG="$HOME/.cursor/mcp.json"
  export CURSOR_AGENTS="$HOME/.cursor/agents"
  export LEGION_MARKETPLACE_ROOT="$ROOT"
  mkdir -p "$HOME/.cursor" "$AGENTS_HOME/skills"

  for s in alpha beta; do
    mkdir -p "$AGENTS_HOME/skills/$s"
    printf -- '---\nname: %s\ndescription: d\n---\nbody\n' "$s" > "$AGENTS_HOME/skills/$s/SKILL.md"
  done

  export PATH="$ROOT/legion-router/bin:$BATS_TEST_DIRNAME/mocks/bin:$PATH"
}

_copy_cursor_setup_scripts() {
  local dest="$1"
  mkdir -p "$dest"
  cp "$ROOT/legion-setup/scripts/legion-cursor-setup.sh" "$dest/"
  cp "$ROOT/legion-setup/scripts/legion-cursor-mcp-merge.py" "$dest/"
  cp "$ROOT/legion-setup/scripts/legion-cursor-bridge.py" "$dest/"
  cp "$ROOT/legion-setup/scripts/legion-marketplace-root.sh" "$dest/"
}

# legion-core ships no MCP plugins itself, so the bridge is exercised against a
# fixture marketplace that declares one (the same shape a consumer adds).
_mkt_with_mcp() {  # $1 = marketplace dir
  mkdir -p "$1/dummy-mcp/.claude-plugin"
  printf '%s\n' '{"name":"dummy-mcp","version":"0.0.0","description":"d","mcpServers":{"dummy":{"command":"echo","args":["hi"]}}}' \
    > "$1/dummy-mcp/.claude-plugin/plugin.json"
}

@test "cursor setup: mcp wires a marketplace MCP server into Cursor; verify confirms it" {
  local mkt="$BATS_TEST_TMPDIR/mkt"; _mkt_with_mcp "$mkt"

  LEGION_MARKETPLACE_ROOT="$mkt" run "$SETUP_SH" mcp
  [ "$status" -eq 0 ]
  jq -e '.mcpServers.dummy.command == "echo"' "$CURSOR_MCP_CONFIG"

  # verify's MCP check confirms it (other readiness checks may be unmet in CI,
  # so assert on the MCP line rather than the overall exit code).
  LEGION_MARKETPLACE_ROOT="$mkt" run "$SETUP_SH" verify
  [[ "$output" == *"ok MCP dummy registered"* ]]
}

@test "cursor setup: mcp merge is idempotent and preserves user servers" {
  mkdir -p "$(dirname "$CURSOR_MCP_CONFIG")"
  printf '%s\n' '{"mcpServers":{"user-server":{"command":"echo","args":["hi"]}}}' > "$CURSOR_MCP_CONFIG"

  "$SETUP_SH" mcp >/dev/null
  local first; first="$(cat "$CURSOR_MCP_CONFIG")"
  "$SETUP_SH" mcp >/dev/null

  [ "$(cat "$CURSOR_MCP_CONFIG")" = "$first" ]
  jq -e '.mcpServers["user-server"].command == "echo"' "$CURSOR_MCP_CONFIG"
}

@test "cursor setup: auto-detects the consumer marketplace when legion-core is vendored" {
  local consumer="$BATS_TEST_TMPDIR/consumer"
  local vendored="$consumer/vendored/legion-core/legion-setup/scripts"
  mkdir -p "$consumer/.claude-plugin" "$consumer/dummy-mcp/.claude-plugin"
  printf '%s\n' '{"name":"consumer","owner":{"name":"o"},"version":"0.0.0","plugins":[{"name":"dummy-mcp","source":"./dummy-mcp"}]}' \
    > "$consumer/.claude-plugin/marketplace.json"
  printf '%s\n' '{"name":"dummy-mcp","version":"0.0.0","description":"d","mcpServers":{"dummy":{"command":"echo","args":["hi"]}}}' \
    > "$consumer/dummy-mcp/.claude-plugin/plugin.json"
  _copy_cursor_setup_scripts "$vendored"

  unset LEGION_MARKETPLACE_ROOT MARKETPLACE_ROOT
  run "$vendored/legion-cursor-setup.sh" mcp
  [ "$status" -eq 0 ]
  jq -e '.mcpServers.dummy.command == "echo"' "$CURSOR_MCP_CONFIG"
}

@test "cursor setup: verify detects a drifted Legion MCP spec" {
  local mkt="$BATS_TEST_TMPDIR/mkt"; _mkt_with_mcp "$mkt"
  # Register a STALE version of the spec, so verify must report drift.
  mkdir -p "$(dirname "$CURSOR_MCP_CONFIG")"
  printf '%s\n' '{"mcpServers":{"dummy":{"command":"/stale/dummy","args":[]}}}' > "$CURSOR_MCP_CONFIG"

  LEGION_MARKETPLACE_ROOT="$mkt" run "$SETUP_SH" verify

  [ "$status" -ne 0 ]
  echo "$output" | grep -q 'MCP dummy registered but drifted'
}

@test "cursor setup: verify requires Legion-generated agents, not any user agent" {
  "$SETUP_SH" mcp >/dev/null
  mkdir -p "$CURSOR_AGENTS"
  printf -- '---\nname: user-agent\ndescription: d\n---\nbody\n' > "$CURSOR_AGENTS/user-agent.md"

  run "$SETUP_SH" verify

  [ "$status" -ne 0 ]
  echo "$output" | grep -q 'no Legion Cursor agents'
}

@test "cursor setup: bridged descriptions stay within Cursor budget" {
  local mkt="$BATS_TEST_TMPDIR/mkt"
  mkdir -p "$mkt/opus-commands/commands"
  local long_desc
  long_desc="$(printf 'very descriptive trigger text for a complex workflow %.0s' {1..20})"
  printf -- '---\ndescription: %s\n---\n\n# Big\nbody\n' "$long_desc" \
    > "$mkt/opus-commands/commands/big.md"

  LEGION_MARKETPLACE_ROOT="$mkt" run "$SETUP_SH" agents
  [ "$status" -eq 0 ]
  python3 - "$CURSOR_AGENTS/legion-cmd-big.md" <<'PY'
import re
import sys
text = open(sys.argv[1], encoding="utf-8").read()
match = re.search(r'^description: "(.*)"$', text, re.M)
assert match, text
assert len(match.group(1)) <= 220, len(match.group(1))
assert "Use when the user asks to 'big'" in match.group(1), match.group(1)
PY
}

@test "cursor mcp merge: rejects invalid existing config clearly" {
  mkdir -p "$(dirname "$CURSOR_MCP_CONFIG")"
  printf '{bad' > "$CURSOR_MCP_CONFIG"
  run bash -c "printf '{\"x\":{\"command\":\"echo\"}}' | '$MERGE_PY' --config '$CURSOR_MCP_CONFIG'"
  [ "$status" -eq 2 ]
  echo "$output" | jq -e '.error | contains("bad Cursor MCP config")'
}
