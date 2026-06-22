#!/usr/bin/env bats

load 'helpers/setup'

setup() {
  setup_test_env
  export ROUTER_SH="$REPO_ROOT/legion-router/scripts/router.sh"
  export WRAPPER_SH="$REPO_ROOT/legion-router/scripts/router-wrapper.sh"
  export TEST_BIN="$BATS_TEST_TMPDIR/router-bin"
  export XDG_CONFIG_HOME="$BATS_TEST_TMPDIR/xdg"
  mkdir -p "$TEST_BIN"
}

write_stub() {
  local name="$1"
  local body="$2"
  printf '%s\n' "$body" > "$TEST_BIN/$name"
  chmod +x "$TEST_BIN/$name"
}

file_mode() {
  local path="$1"
  if stat -f '%Lp' "$path" >/dev/null 2>&1; then
    stat -f '%Lp' "$path"
  else
    stat -c '%a' "$path"
  fi
}

@test "legion-router install on Linux stores credentials via secret-tool without hard-failing" {
  local secret_log="$BATS_TEST_TMPDIR/secret-tool.log"
  write_stub uname '#!/usr/bin/env bash
printf "Linux\n"'
  write_stub secret-tool '#!/usr/bin/env bash
printf "%s\n" "$*" >> "'"$secret_log"'"
if [[ "$1" == "store" ]]; then
  cat >/dev/null
fi'

  PATH="$TEST_BIN:$PATH" run "$ROUTER_SH" install --api-key anthropic-linux --token minimax-linux
  [ "$status" -eq 0 ]
  [[ "$output" == *"stored via secret-tool/libsecret"* ]]
  [[ "$output" == *"install only stored credentials"* ]]
  grep -q 'store --label=Legion Router Anthropic API key service legion-router account legion-anthropic' "$secret_log"
  grep -q 'store --label=Legion Router MiniMax auth token service legion-router account legion-minimax' "$secret_log"
}

@test "legion-router install on Linux falls back to 0600 files when secret-tool is unavailable" {
  local bun_log="$BATS_TEST_TMPDIR/bun-env.log"
  write_stub uname '#!/usr/bin/env bash
printf "Linux\n"'
  write_stub bun '#!/usr/bin/env bash
printf "ANTHROPIC_API_KEY=%s\n" "${ANTHROPIC_API_KEY:-}" > "'"$bun_log"'"
printf "MINIMAX_AUTH_TOKEN=%s\n" "${MINIMAX_AUTH_TOKEN:-}" >> "'"$bun_log"'"
exit 0'

  PATH="$TEST_BIN:$(path_without secret-tool)" run "$ROUTER_SH" install --api-key anthropic-from-file --token minimax-from-file
  [ "$status" -eq 0 ]
  [[ "$output" == *"stored in $XDG_CONFIG_HOME/legion/router/anthropic_api_key"* ]]
  [[ "$output" == *"stored in $XDG_CONFIG_HOME/legion/router/minimax_auth_token"* ]]

  PATH="$TEST_BIN:$(path_without secret-tool)" run /bin/bash "$WRAPPER_SH"
  [ "$status" -eq 0 ]
  grep -qx 'ANTHROPIC_API_KEY=anthropic-from-file' "$bun_log"
  grep -qx 'MINIMAX_AUTH_TOKEN=minimax-from-file' "$bun_log"
  [ "$(file_mode "$XDG_CONFIG_HOME/legion/router/anthropic_api_key")" = "600" ]
  [ "$(file_mode "$XDG_CONFIG_HOME/legion/router/minimax_auth_token")" = "600" ]
}
