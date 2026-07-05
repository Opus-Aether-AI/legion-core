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

@test "legion-code-intel: Pyright adapter parses JSON diagnostics" {
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

  PATH="$fakebin:$PATH" run "$CODE_INTEL" diagnostics --repo "$repo" --adapter pyright --json

  [ "$status" -eq 1 ]
  jq -e '
    .status == "failed"
    and .summary.errors == 1
    and .diagnostics[0].adapter == "pyright"
    and .diagnostics[0].file == "app.py"
    and .diagnostics[0].line == 1
    and .diagnostics[0].column == 8
    and .diagnostics[0].code == "reportMissingImports"
  ' <<<"$output" >/dev/null
}
