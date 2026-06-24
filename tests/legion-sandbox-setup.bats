#!/usr/bin/env bats

load 'helpers/setup'

setup() {
  setup_test_env
  LIB="$REPO_ROOT/legion-router/scripts/lib/sandbox-setup.sh"
  export CUSTOM_BIN="$TEST_TMPDIR/sandbox-mocks"
  export SANDBOX_INSTALL_LOG="$TEST_TMPDIR/install.log"
  export SANDBOX_DEV_LOG="$TEST_TMPDIR/dev.log"
  export SANDBOX_DEV_CHILD_PID="$TEST_TMPDIR/dev-child.pid"
  mkdir -p "$CUSTOM_BIN"
  : > "$SANDBOX_INSTALL_LOG"
  : > "$SANDBOX_DEV_LOG"
  export PATH="$CUSTOM_BIN:$PATH"
  write_install_mocks
}

make_dirs() {
  MAIN_DIR="$TEST_TMPDIR/main-$1"
  WT_DIR="$TEST_TMPDIR/wt-$1"
  mkdir -p "$MAIN_DIR/.legion" "$WT_DIR"
}

write_install_mocks() {
  local cmd
  for cmd in bun pnpm yarn npm custom-install; do
    cat > "$CUSTOM_BIN/$cmd" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s %s %s\n' "$(basename "$0")" "$*" "$PWD" >> "$SANDBOX_INSTALL_LOG"
EOF
    chmod +x "$CUSTOM_BIN/$cmd"
  done
}

write_dev_mock() {
  cat > "$CUSTOM_BIN/dev-server" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$$" > "$SANDBOX_DEV_CHILD_PID"
trap 'printf "terminated\n" >> "$SANDBOX_DEV_LOG"; exit 0' TERM INT
while true; do sleep 1; done
EOF
  chmod +x "$CUSTOM_BIN/dev-server"
}

@test "sandbox_setup: install auto-detect picks lockfile package manager" {
  local entry lock expected
  for entry in \
    "bun.lockb:bun" \
    "bun.lock:bun" \
    "pnpm-lock.yaml:pnpm" \
    "yarn.lock:yarn" \
    "package-lock.json:npm"; do
    lock="${entry%%:*}"
    expected="${entry##*:}"
    make_dirs "auto-$lock"
    : > "$SANDBOX_INSTALL_LOG"
    : > "$WT_DIR/$lock"

    run bash -c "source '$LIB'; sandbox_setup '$WT_DIR' '$MAIN_DIR' 0 >/dev/null"

    [ "$status" -eq 0 ]
    grep -Fq "$expected install $WT_DIR" "$SANDBOX_INSTALL_LOG"
  done
}

@test "sandbox_setup: explicit install command wins over lockfile auto-detect" {
  make_dirs explicit
  printf '{"install":"custom-install"}\n' > "$MAIN_DIR/.legion/sandbox.json"
  : > "$WT_DIR/package-lock.json"

  run bash -c "source '$LIB'; sandbox_setup '$WT_DIR' '$MAIN_DIR' 0 >/dev/null"

  [ "$status" -eq 0 ]
  grep -Fq "custom-install  $WT_DIR" "$SANDBOX_INSTALL_LOG"
  ! grep -Fq "npm install" "$SANDBOX_INSTALL_LOG"
}

@test "sandbox_setup: copy happens for trusted run" {
  make_dirs copy-trusted
  mkdir -p "$MAIN_DIR/config"
  printf 'TOKEN=secret\n' > "$MAIN_DIR/.env"
  printf '{"k":"v"}\n' > "$MAIN_DIR/config/secret.json"
  printf '{"copy":[".env","config/secret.json"]}\n' > "$MAIN_DIR/.legion/sandbox.json"
  local art="$TEST_TMPDIR/copy-artifacts"

  run bash -c "source '$LIB'; LEGION_SANDBOX_ARTIFACT_DIR='$art' sandbox_setup '$WT_DIR' '$MAIN_DIR' 0 >/dev/null"

  [ "$status" -eq 0 ]
  [ "$(cat "$WT_DIR/.env")" = "TOKEN=secret" ]
  [ "$(cat "$WT_DIR/config/secret.json")" = '{"k":"v"}' ]
  jq -e '.copied_secret_names == [".env","config/secret.json"]' "$art/copied-secrets.json"
}

@test "sandbox_setup: copy is skipped for untrusted run" {
  make_dirs copy-untrusted
  printf 'TOKEN=secret\n' > "$MAIN_DIR/.env"
  printf '{"copy":[".env"]}\n' > "$MAIN_DIR/.legion/sandbox.json"
  local err="$TEST_TMPDIR/untrusted.err"

  run bash -c "source '$LIB'; sandbox_setup '$WT_DIR' '$MAIN_DIR' 1 >/dev/null 2>'$err'"

  [ "$status" -eq 0 ]
  [ ! -e "$WT_DIR/.env" ]
  grep -Fq "creds skipped (untrusted run)" "$err"
}

@test "sandbox_setup: dev server starts only when configured and teardown kills it" {
  make_dirs dev
  write_dev_mock
  printf '{"dev":"dev-server"}\n' > "$MAIN_DIR/.legion/sandbox.json"
  local art="$TEST_TMPDIR/artifacts" pid_file="$TEST_TMPDIR/dev.pid"
  mkdir -p "$art"
  export LIB WT_DIR MAIN_DIR art pid_file

  run bash -c '
    source "$LIB"
    pid="$(LEGION_SANDBOX_ARTIFACT_DIR="$art" sandbox_setup "$WT_DIR" "$MAIN_DIR" 0)"
    printf "%s" "$pid" > "$pid_file"
    [[ "$pid" =~ ^[0-9]+$ ]]
    kill -0 "$pid"
    sandbox_teardown "$pid"
    wait "$pid" 2>/dev/null || true
    ! kill -0 "$pid" 2>/dev/null
  '

  [ "$status" -eq 0 ]
  [ -s "$pid_file" ]
  [ -f "$art/sandbox-dev.json" ]
}

@test "sandbox_setup: install stdout does not corrupt the dev PID on stdout" {
  make_dirs dev
  write_dev_mock
  # install prints to stdout; the returned value must still be a bare numeric PID.
  printf '{"install":"echo installing-deps","dev":"dev-server"}\n' > "$MAIN_DIR/.legion/sandbox.json"
  local art="$TEST_TMPDIR/artifacts2"
  mkdir -p "$art"
  export LIB WT_DIR MAIN_DIR art

  run bash -c '
    source "$LIB"
    pid="$(LEGION_SANDBOX_ARTIFACT_DIR="$art" sandbox_setup "$WT_DIR" "$MAIN_DIR" 0)"
    [[ "$pid" =~ ^[0-9]+$ ]]   # no "installing-deps" prepended
    sandbox_teardown "$pid"
    wait "$pid" 2>/dev/null || true
    ! kill -0 "$pid" 2>/dev/null
  '

  [ "$status" -eq 0 ]
}

@test "sandbox_setup: dev server is not started when dev is absent" {
  make_dirs no-dev

  run bash -c "source '$LIB'; pid=\"\$(sandbox_setup '$WT_DIR' '$MAIN_DIR' 0)\"; [ -z \"\$pid\" ]"

  [ "$status" -eq 0 ]
  [ ! -f "$SANDBOX_DEV_CHILD_PID" ]
}

@test "sandbox_setup: missing or invalid sandbox config is a no-op and succeeds" {
  make_dirs missing
  run bash -c "source '$LIB'; sandbox_setup '$WT_DIR' '$MAIN_DIR' 0 >/dev/null"
  [ "$status" -eq 0 ]
  [ ! -s "$SANDBOX_INSTALL_LOG" ]

  make_dirs invalid
  printf '{not json\n' > "$MAIN_DIR/.legion/sandbox.json"
  run bash -c "source '$LIB'; sandbox_setup '$WT_DIR' '$MAIN_DIR' 0 >/dev/null"
  [ "$status" -eq 0 ]
  [ ! -s "$SANDBOX_INSTALL_LOG" ]
}
