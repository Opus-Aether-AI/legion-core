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

@test "cursor setup: all wires MCPs + Cursor agents + skill runner; verify confirms" {
  skip "asserts company MCP plugins (context7/playwright/codebase-memory); legion-core ships none — covered by consumers that add MCP plugins"
  run "$SETUP_SH" all
  [ "$status" -eq 0 ]

  jq -e '.mcpServers.context7 and .mcpServers.playwright and .mcpServers["codebase-memory"]' "$CURSOR_MCP_CONFIG"
  [ -f "$CURSOR_AGENTS/legion-cmd-feature.md" ]
  [ -f "$CURSOR_AGENTS/legion-agent-monorepo-engineer.md" ]
  [ -f "$CURSOR_AGENTS/legion-skill-runner.md" ]
  grep -q "$AGENTS_HOME/skills" "$CURSOR_AGENTS/legion-skill-runner.md"

  run "$SETUP_SH" verify
  [ "$status" -eq 0 ]
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

@test "cursor setup: verify detects drifted Legion MCP specs" {
  skip "asserts company MCP plugins (context7/playwright); legion-core ships none — covered by consumers that add MCP plugins"
  mkdir -p "$(dirname "$CURSOR_MCP_CONFIG")"
  printf '%s\n' '{"mcpServers":{"context7":{"command":"/stale/context7","args":[]}}}' > "$CURSOR_MCP_CONFIG"
  "$SETUP_SH" agents >/dev/null

  run "$SETUP_SH" verify

  [ "$status" -ne 0 ]
  echo "$output" | grep -q 'context7 registered but drifted'
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
