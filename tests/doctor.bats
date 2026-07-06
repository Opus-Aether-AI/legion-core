#!/usr/bin/env bats
# legion-doctor — install verifier. Pass-checks run against a tiny in-test fixture
# (fast under coverage instrumentation); one acceptance test runs the full doctor
# against the real repo. Fail-checks run against a broken fixture. Covers each
# --only check's pass + fail branch.
#
# The Legion-internal checks (marketplace-schema/plugins/costs/telemetry-schema)
# resolve their files from LEGION_ROOT, NOT --repo, so the fixtures are driven via
# the LEGION_ROOT env var. --repo only scopes the frontmatter scan.

setup() {
  REAL="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  DOCTOR="$REAL/legion-observability/bin/legion-doctor"
  BROKEN="$BATS_TEST_TMPDIR/broken"
  mkdir -p "$BROKEN"
  GOOD="$BATS_TEST_TMPDIR/good"
  _make_good "$GOOD"
}

_make_good() {
  local d="$1"
  mkdir -p "$d/.claude-plugin" "$d/p/.claude-plugin" "$d/legion-router/config" "$d/legion-observability/schema"
  printf '%s\n' '{"name":"x","owner":{"name":"o"},"version":"0.0.0","plugins":[{"name":"p","source":"./p"}]}' \
    > "$d/.claude-plugin/marketplace.json"
  printf '%s\n' '{"name":"p","version":"0.0.0","description":"d"}' > "$d/p/.claude-plugin/plugin.json"
  printf -- '---\nname: p\ndescription: d\n---\nbody\n' > "$d/p/SKILL.md"
  printf '%s\n' '{"models":[{"match":"x","input":0,"output":0,"cache_read":0,"cache_write":0}],"default":{"input":0,"output":0,"cache_read":0,"cache_write":0}}' \
    > "$d/legion-router/config/costs.json"
  printf '%s\n' '{"title":"legion.span.v1"}' > "$d/legion-observability/schema/legion.span.v1.schema.json"
}

@test "doctor: acceptance — full run passes on the real repo (0 fail, exit 0)" {
  run "$DOCTOR" --repo "$REAL"
  [ "$status" -eq 0 ]
  [[ "$output" == *"0 fail"* ]]
}

@test "doctor: full run passes on a valid fixture" {
  LEGION_ROOT="$GOOD" run "$DOCTOR" --repo "$GOOD"
  [ "$status" -eq 0 ]
  [[ "$output" == *"0 fail"* ]]
}

@test "doctor: marketplace-schema passes on good, fails on broken" {
  LEGION_ROOT="$GOOD" run "$DOCTOR" --only marketplace-schema
  [ "$status" -eq 0 ]; [[ "$output" == *PASS* ]]
  LEGION_ROOT="$BROKEN" run "$DOCTOR" --only marketplace-schema
  [ "$status" -eq 1 ]; [[ "$output" == *FAIL* ]]
}

@test "doctor: plugins passes on good, fails on broken" {
  LEGION_ROOT="$GOOD" run "$DOCTOR" --only plugins
  [ "$status" -eq 0 ]
  LEGION_ROOT="$BROKEN" run "$DOCTOR" --only plugins
  [ "$status" -eq 1 ]
}

@test "doctor: costs passes on good, warns when absent, fails when invalid" {
  LEGION_ROOT="$GOOD" run "$DOCTOR" --only costs
  [ "$status" -eq 0 ]; [[ "$output" == *PASS* ]]
  # absent (a consumer that installs the engine as a dependency) → WARN, not fail
  LEGION_ROOT="$BROKEN" run "$DOCTOR" --only costs
  [ "$status" -eq 0 ]; [[ "$output" == *WARN* ]]
  # present but malformed → FAIL
  inv="$BATS_TEST_TMPDIR/inv-costs"; mkdir -p "$inv/legion-router/config"
  echo '{}' > "$inv/legion-router/config/costs.json"
  LEGION_ROOT="$inv" run "$DOCTOR" --only costs
  [ "$status" -eq 1 ]; [[ "$output" == *FAIL* ]]
}

@test "doctor: telemetry-schema passes on good, warns when absent, fails when invalid" {
  LEGION_ROOT="$GOOD" run "$DOCTOR" --only telemetry-schema
  [ "$status" -eq 0 ]; [[ "$output" == *PASS* ]]
  LEGION_ROOT="$BROKEN" run "$DOCTOR" --only telemetry-schema
  [ "$status" -eq 0 ]; [[ "$output" == *WARN* ]]
  inv="$BATS_TEST_TMPDIR/inv-tel"; mkdir -p "$inv/legion-observability/schema"
  echo '{"title":"wrong"}' > "$inv/legion-observability/schema/legion.span.v1.schema.json"
  LEGION_ROOT="$inv" run "$DOCTOR" --only telemetry-schema
  [ "$status" -eq 1 ]; [[ "$output" == *FAIL* ]]
}

@test "doctor: frontmatter passes on good, fails on a bad SKILL.md" {
  run "$DOCTOR" --repo "$GOOD" --only frontmatter
  [ "$status" -eq 0 ]
  mkdir -p "$BROKEN/p"; printf 'no frontmatter here\n' > "$BROKEN/p/SKILL.md"
  run "$DOCTOR" --repo "$BROKEN" --only frontmatter
  [ "$status" -eq 1 ]
}

@test "doctor: install-checks pass when --repo is a non-Legion project" {
  # Regression: an agent running the doctor from a product repo (no Legion
  # files) must NOT false-fail the install-checks. LEGION_ROOT resolves to the
  # real install, so --repo at a Legion-less dir only scopes the frontmatter scan.
  LEGION_ROOT="$GOOD" run "$DOCTOR" --repo "$BROKEN" --only marketplace-schema
  [ "$status" -eq 0 ]; [[ "$output" == *PASS* ]]
  LEGION_ROOT="$GOOD" run "$DOCTOR" --repo "$BROKEN" --only costs
  [ "$status" -eq 0 ]; [[ "$output" == *PASS* ]]
}

@test "doctor: emits an INFO line when --repo differs from the install root" {
  LEGION_ROOT="$GOOD" run "$DOCTOR" --repo "$BROKEN" --only marketplace-schema
  [[ "$output" == *INFO* ]]
  [[ "$output" == *"$BROKEN"* ]]
}

@test "doctor: codex check never fails (pass or warn)" {
  run "$DOCTOR" --repo "$GOOD" --only codex
  [ "$status" -eq 0 ]
}

@test "doctor: codex present-but-unauthenticated warns (HOME without auth.json)" {
  HOME="$BATS_TEST_TMPDIR/noauth" run "$DOCTOR" --repo "$GOOD" --only codex
  [ "$status" -eq 0 ]
}

@test "doctor: unknown top-level arg exits 2" {
  run "$DOCTOR" --repo "$GOOD" --bogus
  [ "$status" -eq 2 ]
}

@test "doctor: route-smoke passes with a valid route CLI" {
  fake="$BATS_TEST_TMPDIR/fake-route-ok"; mkdir -p "$fake"
  cat > "$fake/legion-route" <<'EOF'
#!/bin/sh
case "$1" in
  implement-feature) printf '%s\n' '{"executor":"codex","model":"gpt-5.5","sandbox":"workspace-write","resolved":true}' ;;
  final-review) printf '%s\n' '{"executor":"codex","model":"gpt-5.5","sandbox":"read-only","resolved":true}' ;;
  *) exit 2 ;;
esac
EOF
  chmod +x "$fake/legion-route"

  PATH="$fake:$PATH" LEGION_ROOT="$GOOD" run "$DOCTOR" --repo "$GOOD" --only route-smoke
  [ "$status" -eq 0 ]
  [[ "$output" == *"PASS"* ]]
}

@test "doctor: route-smoke fails with the underlying route error" {
  fake="$BATS_TEST_TMPDIR/fake-route-bad"; mkdir -p "$fake"
  cat > "$fake/legion-route" <<'EOF'
#!/bin/sh
echo "tomllib unavailable" >&2
exit 2
EOF
  chmod +x "$fake/legion-route"

  PATH="$fake:$PATH" LEGION_ROOT="$GOOD" run "$DOCTOR" --repo "$GOOD" --only route-smoke
  [ "$status" -eq 1 ]
  [[ "$output" == *"FAIL"* ]]
  [[ "$output" == *"final-review"* ]]
  [[ "$output" == *"tomllib unavailable"* ]]
}

@test "doctor: state-root auto-resolves when LEGION_STATE_ROOT is missing" {
  HOME="$BATS_TEST_TMPDIR/home" LEGION_STATE_ROOT= LEGION_ROOT="$GOOD" run "$DOCTOR" --repo "$GOOD" --only state-root
  [ "$status" -eq 0 ]
  [[ "$output" == *"Legion state root centralizes"* ]]
  [[ "$output" == *".legion/projects"* ]]
}

@test "doctor: strict-demo runs demo-critical checks and passes when they are wired" {
  fake="$BATS_TEST_TMPDIR/fake-strict"; mkdir -p "$fake"
  cat > "$fake/legion-route" <<'EOF'
#!/bin/sh
case "$1" in
  implement-feature) printf '%s\n' '{"executor":"codex","model":"gpt-5.5","sandbox":"workspace-write","resolved":true}' ;;
  final-review) printf '%s\n' '{"executor":"codex","model":"gpt-5.5","sandbox":"read-only","resolved":true}' ;;
  *) exit 2 ;;
esac
EOF
  cat > "$fake/legion-delegate" <<'EOF'
#!/bin/sh
case "$1" in
  -h|--help|help|"") exit 0 ;;
  *) exit 2 ;;
esac
EOF
  cat > "$fake/bats" <<'EOF'
#!/bin/sh
exit 0
EOF
  chmod +x "$fake/legion-route" "$fake/legion-delegate" "$fake/bats"

  PATH="$fake:$PATH" \
    HOME="$BATS_TEST_TMPDIR/home" \
    LEGION_ROOT="$GOOD" \
    LEGION_STATE_ROOT= \
    LEGION_TELEMETRY_DIR= \
    LEGION_REGISTRY_DIR= \
    LEGION_REPOS_FILE= \
    LEGION_BENCH_DIR= \
    run "$DOCTOR" --repo "$GOOD" --strict-demo --json
  [ "$status" -eq 0 ]
  echo "$output" | tail -n 1 | jq -e '[.[].check] | index("route-smoke") and index("delegate-smoke") and index("state-root") and index("test-tools")'
}

@test "doctor: domain-plugin passes when manifest requires legion-run" {
  d="$BATS_TEST_TMPDIR/domain-ok"
  mkdir -p "$d/.legion/plugins/fieldops"
  cat > "$d/.legion/plugins/fieldops/legion-plugin.toml" <<'TOML'
[plugin]
name = "fieldops"
kind = "domain-plugin"

[pipeline]
profile = "legion.full_app.v1"
entrypoint = "legion-run"

[commands]
plan = "fieldops-plan"
validate = "fieldops-validate"
evaluate = "fieldops-eval"
TOML

  run "$DOCTOR" --repo "$d" --only domain-plugin
  [ "$status" -eq 0 ]
  [[ "$output" == *"PASS"* ]]
}

@test "doctor: domain-plugin accepts the generic heavy-task legion-run profile" {
  d="$BATS_TEST_TMPDIR/domain-heavy"
  mkdir -p "$d/.legion/plugins/fieldops"
  cat > "$d/.legion/plugins/fieldops/legion-plugin.toml" <<'TOML'
[plugin]
name = "fieldops"
kind = "domain-plugin"

[pipeline]
profile = "legion.heavy_task.v1"
entrypoint = "legion-run"

[commands]
plan = "fieldops-plan"
validate = "fieldops-validate"
evaluate = "fieldops-eval"
TOML

  run "$DOCTOR" --repo "$d" --only domain-plugin
  [ "$status" -eq 0 ]
  [[ "$output" == *"PASS"* ]]
}

@test "doctor: domain-plugin fails when manifest bypasses legion-run" {
  d="$BATS_TEST_TMPDIR/domain-bad"
  mkdir -p "$d/.legion/plugins/fieldops"
  cat > "$d/.legion/plugins/fieldops/legion-plugin.toml" <<'TOML'
[plugin]
name = "fieldops"
kind = "domain-plugin"

[pipeline]
profile = "legion.full_app.v1"
entrypoint = "custom-runner"

[commands]
plan = "fieldops-plan"
validate = "fieldops-validate"
evaluate = "fieldops-eval"
TOML

  run "$DOCTOR" --repo "$d" --only domain-plugin
  [ "$status" -eq 1 ]
  [[ "$output" == *"domain plugin must run through legion-run"* ]]
}

@test "doctor: router warns (exit 0) when nothing is listening" {
  ROUTER_PORT=59999 run "$DOCTOR" --repo "$GOOD" --only router
  [ "$status" -eq 0 ]
  [[ "$output" == *WARN* ]]
}

@test "doctor: router fails when Claude is configured to force the local proxy" {
  home="$BATS_TEST_TMPDIR/proxy-home"
  mkdir -p "$home/.claude"
  printf '%s\n' '{"env":{"ANTHROPIC_BASE_URL":"http://127.0.0.1:59999"}}' > "$home/.claude/settings.json"

  HOME="$home" ROUTER_PORT=59999 run "$DOCTOR" --repo "$GOOD" --only router
  [ "$status" -eq 1 ]
  [[ "$output" == *"ANTHROPIC_BASE_URL=http://127.0.0.1:59999"* ]]
}

@test "doctor: router fails when ANTHROPIC_BASE_URL env forces the local proxy" {
  ANTHROPIC_BASE_URL="http://localhost:59999" ROUTER_PORT=59999 run "$DOCTOR" --repo "$GOOD" --only router
  [ "$status" -eq 1 ]
  [[ "$output" == *"ANTHROPIC_BASE_URL=http://localhost:59999"* ]]
}

@test "doctor: unknown check exits 2" {
  run "$DOCTOR" --repo "$GOOD" --only nope
  [ "$status" -eq 2 ]
}

@test "doctor: --help exits 0" {
  run "$DOCTOR" --help
  [ "$status" -eq 0 ]
}

# ── descriptions ────────────────────────────────────────────────────────
@test "doctor: descriptions pass on single-line, fail on a block scalar" {
  LEGION_ROOT="$GOOD" run "$DOCTOR" --only descriptions
  [ "$status" -eq 0 ]; [[ "$output" == *PASS* ]]
  bs="$BATS_TEST_TMPDIR/bs"; mkdir -p "$bs/p"
  printf -- '---\nname: p\ndescription: >\n  Multi-line description body.\n---\nbody\n' > "$bs/p/SKILL.md"
  LEGION_ROOT="$bs" run "$DOCTOR" --only descriptions
  [ "$status" -eq 1 ]; [[ "$output" == *FAIL* ]]
}

@test "doctor: descriptions fail on an empty description" {
  e="$BATS_TEST_TMPDIR/empty"; mkdir -p "$e/p"
  printf -- '---\nname: p\ndescription:\n---\nbody\n' > "$e/p/SKILL.md"
  LEGION_ROOT="$e" run "$DOCTOR" --only descriptions
  [ "$status" -eq 1 ]
}

@test "doctor: descriptions scans --repo even when nested under a .legion state root" {
  bad="$BATS_TEST_TMPDIR/state/.legion/bench/run/bad"; mkdir -p "$bad/p"
  printf -- '---\nname: p\ndescription: >\n  Multi-line description body.\n---\nbody\n' > "$bad/p/SKILL.md"

  run "$DOCTOR" --repo "$bad" --only descriptions
  [ "$status" -eq 1 ]
  [[ "$output" == *"block-scalar description"* ]]
}

# ── mcp ─────────────────────────────────────────────────────────────────
@test "doctor: mcp fails on a missing local MCP binary" {
  m="$BATS_TEST_TMPDIR/mcp"; mkdir -p "$m/p/.claude-plugin"
  cat > "$m/p/.claude-plugin/plugin.json" <<'JSON'
{"name":"p","version":"0.0.0","description":"d","mcpServers":{"x":{"command":"${CLAUDE_PLUGIN_ROOT}/bin/nope","args":[]}}}
JSON
  LEGION_ROOT="$m" run "$DOCTOR" --only mcp
  [ "$status" -eq 1 ]; [[ "$output" == *FAIL* ]]
}

@test "doctor: mcp passes on an existing local MCP binary" {
  m="$BATS_TEST_TMPDIR/mcp2"; mkdir -p "$m/p/.claude-plugin" "$m/p/bin"
  printf '#!/bin/sh\n' > "$m/p/bin/srv"; chmod +x "$m/p/bin/srv"
  cat > "$m/p/.claude-plugin/plugin.json" <<'JSON'
{"name":"p","version":"0.0.0","description":"d","mcpServers":{"x":{"command":"${CLAUDE_PLUGIN_ROOT}/bin/srv","args":[]}}}
JSON
  LEGION_ROOT="$m" run "$DOCTOR" --only mcp
  [ "$status" -eq 0 ]; [[ "$output" == *PASS* ]]
}

@test "doctor: mcp fails on a non-existent npm package (needs network)" {
  npm view npm version >/dev/null 2>&1 || skip "no npm/registry access"
  m="$BATS_TEST_TMPDIR/mcp404"; mkdir -p "$m/p/.claude-plugin"
  cat > "$m/p/.claude-plugin/plugin.json" <<'JSON'
{"name":"p","version":"0.0.0","description":"d","mcpServers":{"x":{"command":"npx","args":["-y","@legion-core-legion/this-package-does-not-exist-xyz@latest"]}}}
JSON
  LEGION_ROOT="$m" run "$DOCTOR" --only mcp
  [ "$status" -eq 1 ]; [[ "$output" == *"does not exist"* ]]
}

@test "doctor: mcp skips remote (url) servers without failing" {
  m="$BATS_TEST_TMPDIR/mcp3"; mkdir -p "$m/p/.claude-plugin"
  cat > "$m/p/.claude-plugin/plugin.json" <<'JSON'
{"name":"p","version":"0.0.0","description":"d","mcpServers":{"x":{"url":"https://example.com/mcp"}}}
JSON
  LEGION_ROOT="$m" run "$DOCTOR" --only mcp
  [ "$status" -eq 0 ]
}

# ── bridges ─────────────────────────────────────────────────────────────
@test "doctor: bridges warn-skip (exit 0) when merge scripts are absent" {
  LEGION_ROOT="$GOOD" run "$DOCTOR" --only bridges
  [ "$status" -eq 0 ]
}

# ── self-learn recording ────────────────────────────────────────────────
@test "doctor: --record-failures pipes failures into legion-self-learn" {
  fake="$BATS_TEST_TMPDIR/fakebin"; mkdir -p "$fake"
  log="$BATS_TEST_TMPDIR/record.log"
  cat > "$fake/legion-self-learn" <<EOF
#!/bin/sh
echo "\$@" >> "$log"
EOF
  chmod +x "$fake/legion-self-learn"
  bs="$BATS_TEST_TMPDIR/bsrec"; mkdir -p "$bs/p"
  printf -- '---\nname: p\ndescription: >\n  Multi.\n---\n' > "$bs/p/SKILL.md"
  PATH="$fake:$PATH" LEGION_ROOT="$bs" run "$DOCTOR" --only descriptions --record-failures
  [ "$status" -eq 1 ]
  [ -f "$log" ]
  grep -q "record" "$log"
  grep -q "source legion-doctor" "$log"
}

@test "doctor: failures are NOT recorded without --record-failures" {
  fake="$BATS_TEST_TMPDIR/fakebin2"; mkdir -p "$fake"
  log="$BATS_TEST_TMPDIR/record2.log"
  cat > "$fake/legion-self-learn" <<EOF
#!/bin/sh
echo "\$@" >> "$log"
EOF
  chmod +x "$fake/legion-self-learn"
  bs="$BATS_TEST_TMPDIR/bsrec2"; mkdir -p "$bs/p"
  printf -- '---\nname: p\ndescription: >\n  Multi.\n---\n' > "$bs/p/SKILL.md"
  PATH="$fake:$PATH" LEGION_ROOT="$bs" run "$DOCTOR" --only descriptions
  [ "$status" -eq 1 ]
  [ ! -f "$log" ]
}
