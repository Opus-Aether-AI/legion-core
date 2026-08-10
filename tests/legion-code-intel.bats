#!/usr/bin/env bats

setup() {
  ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  CODE_INTEL="$ROOT/legion-code-intel/bin/legion-code-intel"
  TRACE="$ROOT/legion-observability/bin/legion-trace"
}

make_ts_repo() {
  local repo="$1"
  mkdir -p "$repo/src"
  printf '%s\n' '{"compilerOptions":{"strict":true}}' > "$repo/tsconfig.json"
  printf '%s\n' 'export const n = 1;' > "$repo/src/bad.ts"
  git -C "$repo" init --quiet
  git -C "$repo" -c user.email=test@example.com -c user.name=test add .
  git -C "$repo" -c user.email=test@example.com -c user.name=test commit -q -m init
  printf '%s\n' 'export const n: number = "no";' > "$repo/src/bad.ts"
}

make_fake_tsc() {
  local bin="$1" diag_file="${2:-src/bad.ts}"
  mkdir -p "$bin"
  cat > "$bin/tsc" <<SH
#!/usr/bin/env bash
echo "$diag_file(1,14): error TS2322: Type 'string' is not assignable to type 'number'."
exit 2
SH
  chmod +x "$bin/tsc"
}

@test "legion-code-intel: TypeScript adapter skips cleanly outside TypeScript repos" {
  repo="$BATS_TEST_TMPDIR/plain"
  mkdir -p "$repo"

  run "$CODE_INTEL" diagnostics --repo "$repo" --adapter typescript --json

  [ "$status" -eq 0 ]
  jq -e '
    .schema == "legion.code-intel.v1"
    and .status == "skipped"
    and .summary.adapters_skipped == 1
    and .summary.diagnostics == 0
  ' <<<"$output" >/dev/null
}

@test "legion-code-intel: auto mode ignores incidental TypeScript source without a config" {
  repo="$BATS_TEST_TMPDIR/incidental-ts"
  fakebin="$BATS_TEST_TMPDIR/incidental-bin"
  mkdir -p "$repo" "$fakebin"
  printf '%s\n' 'export const incidental = true' > "$repo/incidental.ts"
  cat > "$fakebin/tsc" <<'SH'
#!/usr/bin/env bash
printf 'unexpected tsc invocation\n' >&2
exit 99
SH
  chmod +x "$fakebin/tsc"

  PATH="$fakebin:$PATH" run "$CODE_INTEL" diagnostics --repo "$repo" --adapter auto --json

  [ "$status" -eq 0 ]
  jq -e '.status == "skipped" and .summary.adapters_run == 0' <<<"$output" >/dev/null
}

@test "legion-code-intel: auto mode ignores incidental Python and unrelated pyproject" {
  repo="$BATS_TEST_TMPDIR/incidental-python"
  fakebin="$BATS_TEST_TMPDIR/incidental-python-bin"
  mkdir -p "$repo" "$fakebin"
  printf '%s\n' 'print("incidental")' > "$repo/app.py"
  printf '%s\n' '[project]' 'name = "incidental"' > "$repo/pyproject.toml"
  cat > "$fakebin/pyright" <<'SH'
#!/usr/bin/env bash
printf 'unexpected pyright invocation\n' >&2
exit 99
SH
  chmod +x "$fakebin/pyright"

  PATH="$fakebin:$PATH" run "$CODE_INTEL" diagnostics --repo "$repo" --adapter auto --json

  [ "$status" -eq 0 ]
  jq -e '.status == "skipped" and .summary.adapters_run == 0' <<<"$output" >/dev/null
}

@test "legion-code-intel: configured nested TypeScript projects each run once" {
  repo="$BATS_TEST_TMPDIR/ts-monorepo"
  fakebin="$BATS_TEST_TMPDIR/ts-monorepo-bin"
  calls="$BATS_TEST_TMPDIR/tsc-calls"
  mkdir -p "$repo/packages/a" "$repo/packages/b" "$fakebin"
  printf '{}\n' > "$repo/packages/a/tsconfig.json"
  printf '{}\n' > "$repo/packages/a/tsconfig.base.json"
  printf '{}\n' > "$repo/packages/b/tsconfig.build.json"
  cat > "$fakebin/tsc" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$TSC_CALLS"
exit 0
SH
  chmod +x "$fakebin/tsc"

  TSC_CALLS="$calls" PATH="$fakebin:$PATH" run "$CODE_INTEL" diagnostics \
    --repo "$repo" --adapter typescript --json

  [ "$status" -eq 0 ]
  [ "$(wc -l < "$calls" | tr -d ' ')" -eq 2 ]
  grep -q -- '--project packages/a/tsconfig.json' "$calls"
  grep -q -- '--project packages/b/tsconfig.build.json' "$calls"
  ! grep -q -- 'tsconfig.base.json' "$calls"
  jq -e '.status == "ok" and (.adapters[0].projects | length) == 2' <<<"$output" >/dev/null
}

@test "legion-code-intel: configured project cap fails closed before execution" {
  repo="$BATS_TEST_TMPDIR/ts-project-cap"
  fakebin="$BATS_TEST_TMPDIR/ts-project-cap-bin"
  calls="$BATS_TEST_TMPDIR/ts-project-cap-calls"
  mkdir -p "$repo/a" "$repo/b" "$repo/c" "$fakebin"
  printf '{}\n' > "$repo/a/tsconfig.json"
  printf '{}\n' > "$repo/b/tsconfig.json"
  printf '{}\n' > "$repo/c/tsconfig.json"
  cat > "$fakebin/tsc" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$TSC_CALLS"
exit 0
SH
  chmod +x "$fakebin/tsc"

  TSC_CALLS="$calls" PATH="$fakebin:$PATH" run "$CODE_INTEL" diagnostics \
    --repo "$repo" --adapter typescript --max-projects 2 --json

  [ "$status" -eq 2 ]
  [ ! -e "$calls" ]
  jq -e '
    .status == "error"
    and .adapters[0].project_count == 3
    and (.adapters[0].parse_error | contains("exceeds configured limit 2"))
  ' <<<"$output" >/dev/null
}

@test "legion-code-intel: timeout is one total adapter deadline" {
  repo="$BATS_TEST_TMPDIR/ts-total-deadline"
  fakebin="$BATS_TEST_TMPDIR/ts-total-deadline-bin"
  calls="$BATS_TEST_TMPDIR/ts-total-deadline-calls"
  mkdir -p "$repo/a" "$repo/b" "$fakebin"
  printf '{}\n' > "$repo/a/tsconfig.json"
  printf '{}\n' > "$repo/b/tsconfig.json"
  cat > "$fakebin/tsc" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$TSC_CALLS"
exec sleep 2
SH
  chmod +x "$fakebin/tsc"

  TSC_CALLS="$calls" PATH="$fakebin:$PATH" run "$CODE_INTEL" diagnostics \
    --repo "$repo" --adapter typescript --timeout 1 --json

  [ "$status" -eq 2 ]
  [ "$(wc -l < "$calls" | tr -d ' ')" -eq 1 ]
  jq -e '
    .status == "error"
    and (.adapters[0].parse_error | contains("adapter deadline exhausted"))
  ' <<<"$output" >/dev/null
}

@test "legion-code-intel: TypeScript diagnostics fail the gate and emit a span" {
  repo="$BATS_TEST_TMPDIR/tsrepo"
  fakebin="$BATS_TEST_TMPDIR/bin"
  spans="$BATS_TEST_TMPDIR/spans"
  make_ts_repo "$repo"
  make_fake_tsc "$fakebin" "src/bad.ts"

  PATH="$fakebin:$PATH" run "$CODE_INTEL" diagnostics \
    --repo "$repo" \
    --adapter typescript \
    --changed-only \
    --base HEAD \
    --emit-span \
    --telemetry-dir "$spans" \
    --json

  [ "$status" -eq 1 ]
  jq -e '
    .status == "failed"
    and .changed_only == true
    and .summary.errors == 1
    and .diagnostics[0].file == "src/bad.ts"
    and .diagnostics[0].code == "TS2322"
    and .span_path
  ' <<<"$output" >/dev/null

  span_path="$(find "$spans" -type f -name '*.jsonl' | head -1)"
  [ -f "$span_path" ]
  jq -e 'select(.executor == "legion-code-intel" and .status == "failed" and .artifacts.errors == 1)' \
    "$span_path" >/dev/null
  run "$TRACE" validate "$span_path"
  [ "$status" -eq 0 ]
}

@test "legion-code-intel: changed-only filters diagnostics outside the diff" {
  repo="$BATS_TEST_TMPDIR/tsrepo-filter"
  fakebin="$BATS_TEST_TMPDIR/bin-filter"
  make_ts_repo "$repo"
  make_fake_tsc "$fakebin" "src/other.ts"

  PATH="$fakebin:$PATH" run "$CODE_INTEL" diagnostics \
    --repo "$repo" \
    --adapter typescript \
    --changed-only \
    --base HEAD \
    --json

  [ "$status" -eq 0 ]
  jq -e '
    .status == "ok"
    and .summary.adapters_run == 1
    and .summary.diagnostics == 0
    and (.changed_files | index("src/bad.ts"))
  ' <<<"$output" >/dev/null
}

@test "legion-code-intel: auto mode detects configured pyproject and parses Pyright diagnostics" {
  repo="$BATS_TEST_TMPDIR/pyrepo"
  fakebin="$BATS_TEST_TMPDIR/pybin"
  mkdir -p "$repo" "$fakebin"
  printf '%s\n' '[tool.pyright]' > "$repo/pyproject.toml"
  printf '%s\n' 'import missing_package' > "$repo/app.py"
  cat > "$fakebin/pyright" <<'SH'
#!/usr/bin/env bash
printf '{"generalDiagnostics":[{"file":"%s","severity":"error","message":"Import could not be resolved","range":{"start":{"line":0,"character":7}},"rule":"reportMissingImports"}]}\n' "$PWD/app.py"
exit 1
SH
  chmod +x "$fakebin/pyright"

  PATH="$fakebin:$PATH" run "$CODE_INTEL" diagnostics --repo "$repo" --adapter auto --json

  [ "$status" -eq 1 ]
  jq -e '
    .status == "failed"
    and .summary.adapters_run == 1
    and .summary.errors == 1
    and .diagnostics[0].adapter == "pyright"
    and .diagnostics[0].file == "app.py"
    and .diagnostics[0].line == 1
    and .diagnostics[0].column == 8
    and .diagnostics[0].code == "reportMissingImports"
  ' <<<"$output" >/dev/null
}

@test "legion-code-intel: configured nested Pyright projects each run once" {
  repo="$BATS_TEST_TMPDIR/pyright-monorepo"
  fakebin="$BATS_TEST_TMPDIR/pyright-monorepo-bin"
  calls="$BATS_TEST_TMPDIR/pyright-calls"
  mkdir -p "$repo/packages/a" "$repo/packages/b" "$fakebin"
  printf '{}\n' > "$repo/packages/a/pyrightconfig.json"
  printf '%s\n' '[tool.pyright]' > "$repo/packages/b/pyproject.toml"
  cat > "$fakebin/pyright" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$PYRIGHT_CALLS"
printf '{"generalDiagnostics":[]}\n'
exit 0
SH
  chmod +x "$fakebin/pyright"

  PYRIGHT_CALLS="$calls" PATH="$fakebin:$PATH" run "$CODE_INTEL" diagnostics \
    --repo "$repo" --adapter pyright --json

  [ "$status" -eq 0 ]
  [ "$(wc -l < "$calls" | tr -d ' ')" -eq 2 ]
  grep -q -- '--project packages/a/pyrightconfig.json' "$calls"
  grep -q -- '--project packages/b/pyproject.toml' "$calls"
  jq -e '.status == "ok" and (.adapters[0].projects | length) == 2' <<<"$output" >/dev/null
}

@test "legion-code-intel: explicit Pyright adapter keeps loose-file fallback" {
  repo="$BATS_TEST_TMPDIR/explicit-python"
  fakebin="$BATS_TEST_TMPDIR/explicit-python-bin"
  mkdir -p "$repo" "$fakebin"
  printf '%s\n' 'print("loose")' > "$repo/app.py"
  cat > "$fakebin/pyright" <<'SH'
#!/usr/bin/env bash
printf '{"generalDiagnostics":[]}\n'
exit 0
SH
  chmod +x "$fakebin/pyright"

  PATH="$fakebin:$PATH" run "$CODE_INTEL" diagnostics --repo "$repo" --adapter pyright --json

  [ "$status" -eq 0 ]
  jq -e '.status == "ok" and .summary.adapters_run == 1' <<<"$output" >/dev/null
}
