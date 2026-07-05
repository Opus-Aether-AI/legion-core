#!/usr/bin/env bats
# legion-codex-setup — wire the Legion marketplace (MCPs + skills) into Codex CLI.
# Self-contained: builds a synthetic marketplace + temp ~/.codex, never touches the
# real ~/.codex/config.toml or the real skill mirror.

setup() {
  ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  SETUP_SH="$ROOT/legion-setup/scripts/legion-codex-setup.sh"
  MERGE_PY="$ROOT/legion-setup/scripts/legion-codex-mcp-merge.py"

  # Synthetic marketplace with two MCP-declaring plugins (one uses CLAUDE_PLUGIN_ROOT).
  MKT="$BATS_TEST_TMPDIR/mkt"
  mkdir -p "$MKT/plug-a/.claude-plugin" "$MKT/plug-b/bin/.claude-plugin" \
           "$MKT/plug-b/.claude-plugin" "$MKT/vendored/nope/.claude-plugin"
  cat > "$MKT/plug-a/.claude-plugin/plugin.json" <<'JSON'
{ "name": "plug-a", "mcpServers": {
    "context7": { "command": "npx", "args": ["-y", "@upstash/context7-mcp@latest"], "env": {} } } }
JSON
  cat > "$MKT/plug-b/.claude-plugin/plugin.json" <<'JSON'
{ "name": "plug-b", "mcpServers": {
    "memory": { "command": "${CLAUDE_PLUGIN_ROOT}/bin/mem", "args": [], "env": {"X":"1"} } } }
JSON
  # A vendored plugin is excluded from discovery.
  cat > "$MKT/vendored/nope/.claude-plugin/plugin.json" <<'JSON'
{ "name": "nope", "mcpServers": { "skip": { "command": "no", "args": [] } } }
JSON

  export LEGION_MARKETPLACE_ROOT="$MKT"
  export CODEX_CONFIG="$BATS_TEST_TMPDIR/codex/config.toml"
  export AGENTS_HOME="$BATS_TEST_TMPDIR/agents"
  export CODEX_SKILLS="$BATS_TEST_TMPDIR/codex/skills"
  mkdir -p "$BATS_TEST_TMPDIR/codex"
}

_copy_codex_setup_scripts() {
  local dest="$1"
  mkdir -p "$dest"
  cp "$ROOT/legion-setup/scripts/legion-codex-setup.sh" "$dest/"
  cp "$ROOT/legion-setup/scripts/legion-codex-mcp-merge.py" "$dest/"
  cp "$ROOT/legion-setup/scripts/legion-codex-bridge.py" "$dest/"
  cp "$ROOT/legion-setup/scripts/legion-marketplace-root.sh" "$dest/"
}

@test "mcp: registers every marketplace MCP server (vendored excluded)" {
  run "$SETUP_SH" mcp
  [ "$status" -eq 0 ]
  grep -q '^\[mcp_servers.context7\]' "$CODEX_CONFIG"
  grep -q '^\[mcp_servers.memory\]' "$CODEX_CONFIG"
  # vendored plugin's server is NOT registered
  ! grep -q '^\[mcp_servers.skip\]' "$CODEX_CONFIG"
}

@test "mcp: resolves \${CLAUDE_PLUGIN_ROOT} to the plugin's absolute dir" {
  "$SETUP_SH" mcp
  grep -qF "command = \"$MKT/plug-b/bin/mem\"" "$CODEX_CONFIG"
  ! grep -q 'CLAUDE_PLUGIN_ROOT' "$CODEX_CONFIG"
}

@test "mcp: is idempotent — second run adds nothing" {
  "$SETUP_SH" mcp
  local first; first="$(cat "$CODEX_CONFIG")"
  run "$SETUP_SH" mcp
  [ "$status" -eq 0 ]
  [ "$(cat "$CODEX_CONFIG")" = "$first" ]
}

@test "mcp: auto-detects the consumer marketplace when legion-core is vendored" {
  local consumer="$BATS_TEST_TMPDIR/consumer"
  local vendored="$consumer/vendored/legion-core/legion-setup/scripts"
  mkdir -p "$consumer/.claude-plugin" "$consumer/dummy-mcp/.claude-plugin"
  printf '%s\n' '{"name":"consumer","owner":{"name":"o"},"version":"0.0.0","plugins":[{"name":"dummy-mcp","source":"./dummy-mcp"}]}' \
    > "$consumer/.claude-plugin/marketplace.json"
  printf '%s\n' '{"name":"dummy-mcp","mcpServers":{"dummy":{"command":"echo","args":["hi"]}}}' \
    > "$consumer/dummy-mcp/.claude-plugin/plugin.json"
  _copy_codex_setup_scripts "$vendored"

  unset LEGION_MARKETPLACE_ROOT MARKETPLACE_ROOT
  run "$vendored/legion-codex-setup.sh" mcp
  [ "$status" -eq 0 ]
  grep -q '^\[mcp_servers.dummy\]' "$CODEX_CONFIG"
}

@test "merge: reconciles a stale marketplace block and preserves unrelated config" {
  mkdir -p "$(dirname "$CODEX_CONFIG")"
  cat > "$CODEX_CONFIG" <<'TOML'
model = "user-configured-model"

[mcp_servers.context7]
command = "MINE"
args = ["custom"]
TOML
  run bash -c "echo '{\"context7\":{\"command\":\"npx\",\"args\":[\"-y\",\"x\"]},\"new\":{\"command\":\"n\",\"args\":[]}}' | python3 '$MERGE_PY' --config '$CODEX_CONFIG'"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.updated == ["context7"] and .added == ["new"]'
  grep -qF 'model = "user-configured-model"' "$CODEX_CONFIG"
  grep -qF 'command = "npx"' "$CODEX_CONFIG"
  ! grep -qF 'command = "MINE"' "$CODEX_CONFIG"
  grep -q '^\[mcp_servers.new\]' "$CODEX_CONFIG"
}

@test "merge: skips an existing server when the rendered spec is current" {
  mkdir -p "$(dirname "$CODEX_CONFIG")"
  echo '{"context7":{"command":"npx","args":["-y","x"]}}' | python3 "$MERGE_PY" --config "$CODEX_CONFIG"
  local first; first="$(cat "$CODEX_CONFIG")"
  run bash -c "echo '{\"context7\":{\"command\":\"npx\",\"args\":[\"-y\",\"x\"]}}' | python3 '$MERGE_PY' --config '$CODEX_CONFIG'"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.skipped == ["context7"] and .updated == [] and .added == []'
  [ "$(cat "$CODEX_CONFIG")" = "$first" ]
}

@test "merge: adds startup timeout for slow MCP servers" {
  mkdir -p "$(dirname "$CODEX_CONFIG")"
  echo '{"playwright":{"command":"npx","args":["-y","@playwright/mcp@latest"]},"codebase-memory":{"command":"/tmp/memory","args":[]}}' \
    | python3 "$MERGE_PY" --config "$CODEX_CONFIG"
  [ "$(grep -c '^startup_timeout_sec = 120$' "$CODEX_CONFIG")" -eq 2 ]
}

@test "merge: --force re-renders an existing server" {
  mkdir -p "$(dirname "$CODEX_CONFIG")"
  printf '[mcp_servers.context7]\ncommand = "OLD"\nargs = []\n' > "$CODEX_CONFIG"
  run bash -c "echo '{\"context7\":{\"command\":\"NEW\",\"args\":[\"z\"]}}' | python3 '$MERGE_PY' --config '$CODEX_CONFIG' --force"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.updated == ["context7"]'
  grep -qF 'command = "NEW"' "$CODEX_CONFIG"
  ! grep -qF 'command = "OLD"' "$CODEX_CONFIG"
}

@test "merge: url-style server renders url + bearer_token_env_var" {
  echo '{"vercel":{"url":"https://mcp.vercel.com","bearer_token_env_var":"VERCEL_TOKEN"}}' \
    | python3 "$MERGE_PY" --config "$CODEX_CONFIG"
  grep -qF 'url = "https://mcp.vercel.com"' "$CODEX_CONFIG"
  grep -qF 'bearer_token_env_var = "VERCEL_TOKEN"' "$CODEX_CONFIG"
}

@test "merge: dry-run reports without writing" {
  run bash -c "echo '{\"a\":{\"command\":\"x\",\"args\":[]}}' | python3 '$MERGE_PY' --config '$CODEX_CONFIG' --dry-run"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.added == ["a"]'
  [ ! -f "$CODEX_CONFIG" ]
}

@test "skills: --fix mirrors agent skills into the codex skills dir" {
  mkdir -p "$AGENTS_HOME/skills/foo" "$AGENTS_HOME/skills/bar"
  printf 'x\n' > "$AGENTS_HOME/skills/foo/SKILL.md"
  printf 'y\n' > "$AGENTS_HOME/skills/bar/SKILL.md"
  run "$SETUP_SH" skills --fix
  [ "$status" -eq 0 ]
  [ -f "$CODEX_SKILLS/foo/SKILL.md" ]
  [ -f "$CODEX_SKILLS/bar/SKILL.md" ]
}

@test "bridge: turns subagents + slash commands into prefixed Codex skills" {
  mkdir -p "$MKT/opus-monorepo/agents" "$MKT/opus-commands/commands"
  printf -- '---\nname: mono\ndescription: turborepo work\ntools: ["Bash"]\nmodel: sonnet\n---\n\n# Mono\nbody\n' \
    > "$MKT/opus-monorepo/agents/mono.md"
  printf -- '---\ndescription: ship a feature\n---\n\n# Feature\n$ARGUMENTS\n' \
    > "$MKT/opus-commands/commands/feature.md"
  run "$SETUP_SH" bridge
  [ "$status" -eq 0 ]
  [ -f "$CODEX_SKILLS/legion-agent-mono/SKILL.md" ]
  [ -f "$CODEX_SKILLS/legion-cmd-feature/SKILL.md" ]
  # frontmatter: name matches dir, description is double-quoted (strict YAML)
  grep -q '^name: legion-agent-mono$' "$CODEX_SKILLS/legion-agent-mono/SKILL.md"
  grep -q '^description: "' "$CODEX_SKILLS/legion-cmd-feature/SKILL.md"
  # body preserved (the command still references $ARGUMENTS)
  grep -qF '$ARGUMENTS' "$CODEX_SKILLS/legion-cmd-feature/SKILL.md"
}

@test "bridge: keeps generated descriptions within Codex budget" {
  mkdir -p "$MKT/opus-commands/commands"
  local long_desc
  long_desc="$(printf 'very descriptive trigger text for a complex workflow %.0s' {1..20})"
  printf -- '---\ndescription: %s\n---\n\n# Big\nbody\n' "$long_desc" \
    > "$MKT/opus-commands/commands/big.md"

  run "$SETUP_SH" bridge
  [ "$status" -eq 0 ]
  python3 - "$CODEX_SKILLS/legion-cmd-big/SKILL.md" <<'PY'
import re
import sys
text = open(sys.argv[1], encoding="utf-8").read()
match = re.search(r'^description: "(.*)"$', text, re.M)
assert match, text
assert len(match.group(1)) <= 220, len(match.group(1))
assert "Use when the user asks to 'big'" in match.group(1), match.group(1)
PY
}

@test "bridge: is self-pruning — a removed command's skill disappears" {
  mkdir -p "$MKT/opus-commands/commands"
  printf -- '---\ndescription: x\n---\n\nbody\n' > "$MKT/opus-commands/commands/gone.md"
  "$SETUP_SH" bridge
  [ -d "$CODEX_SKILLS/legion-cmd-gone" ]
  rm "$MKT/opus-commands/commands/gone.md"
  "$SETUP_SH" bridge
  [ ! -d "$CODEX_SKILLS/legion-cmd-gone" ]
}

@test "bridge: ignores the .legion worktree copies (no duplicate matches)" {
  mkdir -p "$MKT/opus-monorepo/agents" "$MKT/.legion/worktrees/w1/opus-monorepo/agents"
  printf -- '---\nname: a\ndescription: d\n---\n\nb\n' > "$MKT/opus-monorepo/agents/a.md"
  cp "$MKT/opus-monorepo/agents/a.md" "$MKT/.legion/worktrees/w1/opus-monorepo/agents/a.md"
  run "$SETUP_SH" bridge
  [ "$status" -eq 0 ]
  echo "$output" | grep -qE 'Bridged 1 skills|Bridged 1 skill'
}

@test "verify: flags missing MCPs then passes once registered" {
  mkdir -p "$AGENTS_HOME/skills/foo"; : > "$CODEX_CONFIG"
  run "$SETUP_SH" verify
  [ "$status" -ne 0 ]
  echo "$output" | grep -q 'MCP not registered'
  "$SETUP_SH" mcp
  "$SETUP_SH" skills --fix >/dev/null 2>&1 || true
  run "$SETUP_SH" verify
  # MCP + skills now satisfied; legion-claude/codex may still be absent in CI,
  # so we only assert the MCP line flipped to registered.
  echo "$output" | grep -q 'context7 registered'
}
