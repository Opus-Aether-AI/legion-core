#!/usr/bin/env bats
# legion-opencode-setup — wire Legion MCPs into opencode + verify, without
# touching the user's real ~/.config/opencode.

setup() {
  ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  SETUP_SH="$ROOT/legion-setup/scripts/legion-opencode-setup.sh"
  MERGE_PY="$ROOT/legion-setup/scripts/legion-opencode-mcp-merge.py"

  export HOME="$BATS_TEST_TMPDIR/home"
  export AGENTS_HOME="$BATS_TEST_TMPDIR/agents"
  export OPENCODE_CONFIG="$HOME/.config/opencode/opencode.json"
  mkdir -p "$HOME/.config/opencode" "$AGENTS_HOME/skills/alpha"
  printf -- '---\nname: alpha\ndescription: d\n---\nbody\n' > "$AGENTS_HOME/skills/alpha/SKILL.md"
  export PATH="$ROOT/legion-router/bin:$BATS_TEST_DIRNAME/mocks/bin:$PATH"
}

_mkt_with_mcp() {  # $1 = marketplace dir
  mkdir -p "$1/dummy-mcp/.claude-plugin"
  printf '%s\n' '{"name":"dummy-mcp","version":"0.0.0","description":"d","mcpServers":{"dummy":{"command":"echo","args":["hi"],"env":{"K":"v"}}}}' \
    > "$1/dummy-mcp/.claude-plugin/plugin.json"
}

@test "opencode mcp merge: translates Claude stdio + remote to opencode schema" {
  echo '{"ctx7":{"command":"npx","args":["-y","c"],"env":{"K":"v"}},"rmt":{"url":"https://x/mcp"}}' \
    | python3 "$MERGE_PY" --config "$OPENCODE_CONFIG"
  run jq -e '.mcp.ctx7.type == "local" and .mcp.ctx7.command == ["npx","-y","c"] and .mcp.ctx7.enabled == true and .mcp.ctx7.environment.K == "v"' "$OPENCODE_CONFIG"
  [ "$status" -eq 0 ]
  run jq -e '.mcp.rmt.type == "remote" and .mcp.rmt.url == "https://x/mcp"' "$OPENCODE_CONFIG"
  [ "$status" -eq 0 ]
  run jq -e '.["$schema"] == "https://opencode.ai/config.json"' "$OPENCODE_CONFIG"
  [ "$status" -eq 0 ]
}

@test "opencode mcp merge: idempotent (identical spec is skipped)" {
  echo '{"ctx7":{"command":"npx"}}' | python3 "$MERGE_PY" --config "$OPENCODE_CONFIG" >/dev/null
  run bash -c "echo '{\"ctx7\":{\"command\":\"npx\"}}' | python3 '$MERGE_PY' --config '$OPENCODE_CONFIG'"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.skipped == ["ctx7"] and .added == []'
}

@test "opencode mcp merge: drift needs --force" {
  echo '{"ctx7":{"command":"npx"}}' | python3 "$MERGE_PY" --config "$OPENCODE_CONFIG" >/dev/null
  # different command -> drifted; without --force it is left + reported skipped
  run bash -c "echo '{\"ctx7\":{\"command\":\"bunx\"}}' | python3 '$MERGE_PY' --config '$OPENCODE_CONFIG'"
  echo "$output" | jq -e '.skipped == ["ctx7"]'
  run jq -r '.mcp.ctx7.command[0]' "$OPENCODE_CONFIG"
  [ "$output" = "npx" ]
  # with --force it updates
  run bash -c "echo '{\"ctx7\":{\"command\":\"bunx\"}}' | python3 '$MERGE_PY' --config '$OPENCODE_CONFIG' --force"
  echo "$output" | jq -e '.updated == ["ctx7"]'
  run jq -r '.mcp.ctx7.command[0]' "$OPENCODE_CONFIG"
  [ "$output" = "bunx" ]
}

@test "opencode mcp merge: preserves unrelated existing config keys" {
  printf '%s\n' '{"model":"minimax/MiniMax-M2","theme":"dark"}' > "$OPENCODE_CONFIG"
  echo '{"ctx7":{"command":"npx"}}' | python3 "$MERGE_PY" --config "$OPENCODE_CONFIG" >/dev/null
  run jq -e '.model == "minimax/MiniMax-M2" and .theme == "dark" and (.mcp.ctx7.type == "local")' "$OPENCODE_CONFIG"
  [ "$status" -eq 0 ]
}

@test "opencode mcp merge: rejects invalid existing config clearly" {
  printf 'not json' > "$OPENCODE_CONFIG"
  run bash -c "echo '{\"ctx7\":{\"command\":\"npx\"}}' | python3 '$MERGE_PY' --config '$OPENCODE_CONFIG'"
  [ "$status" -ne 0 ]
  echo "$output" | jq -e '.error | test("not valid JSON")'
}

@test "opencode setup mcp: registers marketplace MCP servers into opencode.json" {
  local mkt="$BATS_TEST_TMPDIR/mkt"; _mkt_with_mcp "$mkt"
  LEGION_MARKETPLACE_ROOT="$mkt" run "$SETUP_SH" mcp
  [ "$status" -eq 0 ]
  run jq -e '.mcp.dummy.type == "local" and .mcp.dummy.command == ["echo","hi"] and .mcp.dummy.environment.K == "v"' "$OPENCODE_CONFIG"
  [ "$status" -eq 0 ]
}

@test "opencode setup verify: reports missing MCP and available skills" {
  local mkt="$BATS_TEST_TMPDIR/mkt"; _mkt_with_mcp "$mkt"
  LEGION_MARKETPLACE_ROOT="$mkt" run "$SETUP_SH" verify
  # dummy MCP declared but not yet registered -> non-zero, with a clear hint
  [ "$status" -ne 0 ]
  [[ "$output" == *"missing MCP dummy"* ]]
  [[ "$output" == *"skills available to opencode"* ]]
}
