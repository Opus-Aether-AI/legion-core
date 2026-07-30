#!/usr/bin/env bats

setup() {
  ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  INIT="$ROOT/legion-setup/bin/legion-init"
  SETUP="$ROOT/legion-setup/bin/legion-setup"
  REPO="$BATS_TEST_TMPDIR/repo"
  mkdir -p "$REPO"
  git -C "$REPO" init -q
}

@test "legion-init preserves existing instructions and adds managed blocks" {
  printf '# Existing agents\n\nKeep this exact.\n' > "$REPO/AGENTS.md"
  printf '# Existing Claude\n\nClaude-only rule.\n' > "$REPO/CLAUDE.md"

  run "$INIT" --repo "$REPO" --json
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.ok == true and .changed == true'
  grep -Fq 'Keep this exact.' "$REPO/AGENTS.md"
  grep -Fq 'Claude-only rule.' "$REPO/CLAUDE.md"
  head -n 1 "$REPO/AGENTS.md" | grep -Fxq '<!-- legion:init:v1:agents:start -->'
  head -n 1 "$REPO/CLAUDE.md" | grep -Fxq '<!-- legion:init:v1:claude:start -->'
  [ "$(grep -c '<!-- legion:init:v1:agents:start -->' "$REPO/AGENTS.md")" -eq 1 ]
  [ "$(grep -c '<!-- legion:init:v1:claude:start -->' "$REPO/CLAUDE.md")" -eq 1 ]
  grep -Fq '@AGENTS.md' "$REPO/CLAUDE.md"
  [ "$(grep -n '^@AGENTS.md$' "$REPO/CLAUDE.md" | cut -d: -f1)" -le 3 ]
}

@test "legion-init is idempotent and check passes when current" {
  "$INIT" --repo "$REPO" >/dev/null
  before="$(shasum "$REPO/AGENTS.md" "$REPO/CLAUDE.md")"
  run "$INIT" --repo "$REPO" --check --json
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.ok == true and .changed == false'
  "$INIT" --repo "$REPO" >/dev/null
  after="$(shasum "$REPO/AGENTS.md" "$REPO/CLAUDE.md")"
  [ "$before" = "$after" ]
}

@test "legion-init check detects stale managed content without writing" {
  "$INIT" --repo "$REPO" >/dev/null
  sed -i.bak 's/Legion is the mandatory/Legion was once the/' "$REPO/AGENTS.md"
  rm "$REPO/AGENTS.md.bak"
  before="$(shasum "$REPO/AGENTS.md")"
  run "$INIT" --repo "$REPO" --check --json
  [ "$status" -eq 1 ]
  echo "$output" | jq -e '.ok == false and .changed == true'
  [ "$before" = "$(shasum "$REPO/AGENTS.md")" ]
}

@test "legion-init dry-run creates no files" {
  run "$INIT" --repo "$REPO" --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == *"--- $REPO/AGENTS.md"* ]]
  [[ "$output" == *"+++ $REPO/CLAUDE.md"* ]]
  [[ "$output" == *"legion:init:v1:agents:start"* ]]
  [ ! -e "$REPO/AGENTS.md" ]
  [ ! -e "$REPO/CLAUDE.md" ]
}

@test "legion-init read-only modes do not require writable Git metadata" {
  "$INIT" --repo "$REPO" >/dev/null
  rm -f "$REPO/.git/legion-init.lock"
  mkdir "$REPO/.git/legion-init.lock"
  run "$INIT" --repo "$REPO" --check --json
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.ok == true and .changed == false'
  run "$INIT" --repo "$REPO" --dry-run --json
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.ok == true and .changed == false'
}

@test "legion-init updates only the managed block" {
  printf 'before\n' > "$REPO/AGENTS.md"
  "$INIT" --repo "$REPO" >/dev/null
  sed -i.bak 's/Legion is the mandatory/Legion was once the/' "$REPO/AGENTS.md"
  rm "$REPO/AGENTS.md.bak"
  printf '\nafter\n' >> "$REPO/AGENTS.md"
  printf '@AGENTS.md\n\nClaude suffix\n' > "$REPO/CLAUDE.md"
  run "$INIT" --repo "$REPO"
  [ "$status" -eq 0 ]
  grep -Fxq before "$REPO/AGENTS.md"
  tail -n 1 "$REPO/AGENTS.md" | grep -Fxq after
  grep -Fq 'Claude suffix' "$REPO/CLAUDE.md"
  [ "$(grep -c '^@AGENTS.md$' "$REPO/CLAUDE.md")" -eq 1 ]
}

@test "legion-init does not mistake a fenced example for the Claude import" {
  printf '# Existing\n\n```md\n@AGENTS.md\n```\n' > "$REPO/CLAUDE.md"
  "$INIT" --repo "$REPO" >/dev/null
  [ "$(grep -c '^@AGENTS.md$' "$REPO/CLAUDE.md")" -eq 2 ]
  python3 - "$REPO/CLAUDE.md" <<'PY'
from pathlib import Path
import sys

text = Path(sys.argv[1]).read_text()
block = text.split("<!-- legion:init:v1:claude:end -->", 1)[0]
assert "@AGENTS.md" in block
PY
}

@test "legion-init recognizes active inline and relative Claude imports" {
  printf '# Existing\n\nUse @./AGENTS.md for shared policy.\n' > "$REPO/CLAUDE.md"
  "$INIT" --repo "$REPO" >/dev/null
  [ "$(grep -c '@AGENTS.md' "$REPO/CLAUDE.md")" -eq 0 ]
  [ "$(grep -c '@./AGENTS.md' "$REPO/CLAUDE.md")" -eq 1 ]

  "$INIT" --repo "$REPO" --remove >/dev/null
  printf '# Existing\n\n<!-- @AGENTS.md is only an example -->\n' > "$REPO/CLAUDE.md"
  "$INIT" --repo "$REPO" >/dev/null
  [ "$(grep -c '^@AGENTS.md$' "$REPO/CLAUDE.md")" -eq 1 ]
}

@test "legion-init fails closed on malformed markers" {
  printf 'keep\n<!-- legion:init:v1:agents:start -->\nunterminated\n' > "$REPO/AGENTS.md"
  before="$(shasum "$REPO/AGENTS.md")"
  run "$INIT" --repo "$REPO" --json
  [ "$status" -eq 2 ]
  echo "$output" | jq -e '.ok == false and (.error | contains("malformed managed block"))'
  [ "$before" = "$(shasum "$REPO/AGENTS.md")" ]
  [ ! -e "$REPO/CLAUDE.md" ]
}

@test "legion-init fails closed on nested or mismatched markers" {
  printf '<!-- legion:init:v1:agents:start -->\n<!-- legion:init:v1:padding-before=0;padding-after=0;created=0;sha256=0000000000000000 -->\n<!-- legion:init:v1:claude:start -->\n<!-- legion:init:v1:agents:end -->\n' > "$REPO/AGENTS.md"
  before="$(shasum "$REPO/AGENTS.md")"
  run "$INIT" --repo "$REPO" --json
  [ "$status" -eq 2 ]
  echo "$output" | jq -e '.ok == false and (.error | test("nested|mismatched"))'
  [ "$before" = "$(shasum "$REPO/AGENTS.md")" ]
  [ ! -e "$REPO/CLAUDE.md" ]
}

@test "legion-init refuses symlink targets without modifying either file" {
  printf 'external\n' > "$BATS_TEST_TMPDIR/external-agents"
  ln -s "$BATS_TEST_TMPDIR/external-agents" "$REPO/AGENTS.md"
  run "$INIT" --repo "$REPO" --json
  [ "$status" -eq 2 ]
  echo "$output" | jq -e '.ok == false and (.error | contains("refusing to modify symlink"))'
  [ "$(cat "$BATS_TEST_TMPDIR/external-agents")" = "external" ]
  [ ! -e "$REPO/CLAUDE.md" ]
}

@test "legion-init preflights both targets before writing either" {
  printf 'original agents\n' > "$REPO/AGENTS.md"
  before="$(shasum "$REPO/AGENTS.md")"
  mkdir "$REPO/CLAUDE.md"
  run "$INIT" --repo "$REPO" --json
  [ "$status" -eq 2 ]
  echo "$output" | jq -e '.ok == false and (.error | contains("non-file"))'
  [ "$before" = "$(shasum "$REPO/AGENTS.md")" ]
}

@test "legion-init transaction restores the first file when the second write fails" {
  printf 'original agents\n' > "$REPO/AGENTS.md"
  printf 'original claude\n' > "$REPO/CLAUDE.md"
  run python3 - "$ROOT" "$REPO" <<'PY'
import importlib.util
from pathlib import Path
import sys

root = Path(sys.argv[1])
repo = Path(sys.argv[2])
spec = importlib.util.spec_from_file_location("legion_init", root / "legion-setup/scripts/legion-init.py")
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
files = [
    {
        "path": str(repo / "AGENTS.md"), "changed": True, "_delete": False,
        "_desired": "new agents\n", "_current": "original agents\n",
        "exists": True, "_mode": 0o644,
    },
    {
        "path": str(repo / "CLAUDE.md"), "changed": True, "_delete": False,
        "_desired": "new claude\n", "_current": "original claude\n",
        "exists": True, "_mode": 0o644,
    },
]
real_write = module._atomic_write

def fail_second(path, content):
    if path.name == "CLAUDE.md":
        raise OSError("injected second-write failure")
    real_write(path, content)

module._atomic_write = fail_second
try:
    module._apply_transaction(files, remove=False)
except module.InitError:
    pass
else:
    raise AssertionError("transaction unexpectedly succeeded")
assert (repo / "AGENTS.md").read_bytes() == b"original agents\n"
assert (repo / "CLAUDE.md").read_bytes() == b"original claude\n"
PY
  [ "$status" -eq 0 ]
}

@test "legion-init remove deletes only managed blocks" {
  printf 'agents prefix\n' > "$REPO/AGENTS.md"
  printf 'claude prefix\n' > "$REPO/CLAUDE.md"
  "$INIT" --repo "$REPO" >/dev/null
  run "$INIT" --repo "$REPO" --remove --json
  [ "$status" -eq 0 ]
  grep -Fq 'agents prefix' "$REPO/AGENTS.md"
  grep -Fq 'claude prefix' "$REPO/CLAUDE.md"
  ! grep -Fq 'legion:init:' "$REPO/AGENTS.md"
  ! grep -Fq 'legion:init:' "$REPO/CLAUDE.md"
}

@test "legion-init authenticates metadata before removal and repairs it explicitly" {
  printf 'agents prefix\n' > "$REPO/AGENTS.md"
  "$INIT" --repo "$REPO" >/dev/null
  sed -i.bak 's/created=0/created=1/' "$REPO/AGENTS.md"
  rm "$REPO/AGENTS.md.bak"

  run "$INIT" --repo "$REPO" --remove --json
  [ "$status" -eq 2 ]
  echo "$output" | jq -e '.ok == false and (.error | contains("integrity check failed"))'
  grep -Fq 'agents prefix' "$REPO/AGENTS.md"

  "$INIT" --repo "$REPO" >/dev/null
  "$INIT" --repo "$REPO" --remove >/dev/null
  [ "$(cat "$REPO/AGENTS.md")" = "agents prefix" ]
}

@test "legion-init removal preserves content later added before its block" {
  printf 'original agents\n' > "$REPO/AGENTS.md"
  "$INIT" --repo "$REPO" >/dev/null
  python3 - "$REPO/AGENTS.md" <<'PY'
from pathlib import Path
import sys

path = Path(sys.argv[1])
path.write_bytes(b"later prefix\n" + path.read_bytes())
PY
  "$INIT" --repo "$REPO" --remove >/dev/null
  [ "$(cat "$REPO/AGENTS.md")" = $'later prefix\noriginal agents' ]
}

@test "legion-init preserves and flags unmanaged duplicate Claude policy" {
  printf '# Claude\n\n## Legion workflow\n\nKeep this custom rule.\n' > "$REPO/CLAUDE.md"
  run "$INIT" --repo "$REPO" --json
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.warnings | length == 1'
  grep -Fq 'Keep this custom rule.' "$REPO/CLAUDE.md"
  run "$INIT" --repo "$REPO" --check --json
  [ "$status" -eq 1 ]
  echo "$output" | jq -e '.ok == false and (.warnings | length == 1)'
}

@test "legion-init remove is byte-exact and preserves modes and line endings" {
  printf 'agents\r\nwithout final newline' > "$REPO/AGENTS.md"
  printf '@AGENTS.md\r\nClaude-specific\r\n' > "$REPO/CLAUDE.md"
  chmod 600 "$REPO/AGENTS.md"
  chmod 640 "$REPO/CLAUDE.md"
  before_hashes="$(shasum "$REPO/AGENTS.md" "$REPO/CLAUDE.md")"
  "$INIT" --repo "$REPO" >/dev/null
  [ "$(python3 -c 'import os,sys; print(oct(os.stat(sys.argv[1]).st_mode & 0o777))' "$REPO/AGENTS.md")" = "0o600" ]
  [ "$(python3 -c 'import os,sys; print(oct(os.stat(sys.argv[1]).st_mode & 0o777))' "$REPO/CLAUDE.md")" = "0o640" ]
  "$INIT" --repo "$REPO" --remove >/dev/null
  [ "$before_hashes" = "$(shasum "$REPO/AGENTS.md" "$REPO/CLAUDE.md")" ]
}

@test "legion-init tolerates a repository-wide line-ending conversion" {
  printf 'agents\n' > "$REPO/AGENTS.md"
  printf 'claude\n' > "$REPO/CLAUDE.md"
  "$INIT" --repo "$REPO" >/dev/null
  python3 - "$REPO" <<'PY'
from pathlib import Path
import sys

for name in ("AGENTS.md", "CLAUDE.md"):
    path = Path(sys.argv[1]) / name
    path.write_bytes(path.read_bytes().replace(b"\r\n", b"\n").replace(b"\n", b"\r\n"))
PY
  converted_hashes="$(shasum "$REPO/AGENTS.md" "$REPO/CLAUDE.md")"
  run "$INIT" --repo "$REPO" --check --json
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.ok == true and .changed == false'
  "$INIT" --repo "$REPO" --remove >/dev/null
  [ "$(python3 -c 'from pathlib import Path; import sys; print(repr(Path(sys.argv[1]).read_bytes()))' "$REPO/AGENTS.md")" = "b'agents\\r\\n'" ]
  [ "$(python3 -c 'from pathlib import Path; import sys; print(repr(Path(sys.argv[1]).read_bytes()))' "$REPO/CLAUDE.md")" = "b'claude\\r\\n'" ]
  [ "$converted_hashes" != "$(shasum "$REPO/AGENTS.md" "$REPO/CLAUDE.md")" ]
}

@test "legion-init remove deletes files that it created" {
  "$INIT" --repo "$REPO" >/dev/null
  [ -f "$REPO/AGENTS.md" ]
  [ -f "$REPO/CLAUDE.md" ]
  "$INIT" --repo "$REPO" --remove >/dev/null
  [ ! -e "$REPO/AGENTS.md" ]
  [ ! -e "$REPO/CLAUDE.md" ]
}

@test "legion-init resolves a nested path to the Git root" {
  mkdir -p "$REPO/packages/app"
  physical_repo="$(cd "$REPO" && pwd -P)"
  run "$INIT" --repo "$REPO/packages/app" --json
  [ "$status" -eq 0 ]
  echo "$output" | jq -e --arg repo "$physical_repo" '.repo == $repo'
  [ -f "$REPO/AGENTS.md" ]
  [ ! -e "$REPO/packages/app/AGENTS.md" ]
}

@test "legion-init fails closed on case-colliding instruction files" {
  printf 'different case\n' > "$REPO/Agents.md"
  run "$INIT" --repo "$REPO" --json
  [ "$status" -eq 2 ]
  echo "$output" | jq -e '.ok == false and (.error | contains("case-colliding"))'
  [ "$(cat "$REPO/Agents.md")" = "different case" ]
  [ ! -e "$REPO/CLAUDE.md" ]
}

@test "concurrent legion-init calls serialize and stay idempotent" {
  run bash -c '"$1" --repo "$2" >/dev/null & a=$!; "$1" --repo "$2" >/dev/null & b=$!; wait "$a"; wait "$b"' _ "$INIT" "$REPO"
  [ "$status" -eq 0 ]
  run "$INIT" --repo "$REPO" --check --json
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.ok == true and .changed == false'
}

@test "legion-setup init dispatches to legion-init" {
  run "$SETUP" init --repo "$REPO" --json
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.schema == "legion.init.v1" and .ok == true'
}
