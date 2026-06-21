#!/usr/bin/env bats
# legion-heal — detect→delegate→gate→PR. The codex delegation + gh are stubbed
# (env-injected) so the full orchestration is exercised hermetically: a fixture
# repo with one real defect (a block-scalar description) is healed end-to-end.

setup() {
  REAL="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  HEAL="$REAL/legion-observability/scripts/legion-heal.sh"
  DOCTOR="$REAL/legion-observability/bin/legion-doctor"
  STUB="$BATS_TEST_TMPDIR/stub"; mkdir -p "$STUB"
  GH_LOG="$BATS_TEST_TMPDIR/gh.log"
  REPO="$BATS_TEST_TMPDIR/repo"
  _mkrepo "$REPO"
}

# A near-complete Legion-install fixture whose ONLY doctor FAIL is the
# block-scalar description (everything else present + valid).
_mkrepo() {
  local d="$1"
  git init -q "$d"; git -C "$d" config user.email t@t; git -C "$d" config user.name t
  git -C "$d" symbolic-ref HEAD refs/heads/main
  mkdir -p "$d/.claude-plugin" "$d/p/.claude-plugin" "$d/legion-router/config" "$d/legion-observability/schema"
  printf '%s\n' '{"name":"x","owner":{"name":"o"},"version":"0.0.0","plugins":[{"name":"p","source":"./p"}]}' > "$d/.claude-plugin/marketplace.json"
  printf '%s\n' '{"name":"p","version":"0.0.0","description":"d"}' > "$d/p/.claude-plugin/plugin.json"
  printf '%s\n' '{"models":[{"match":"x","input":0,"output":0,"cache_read":0,"cache_write":0}],"default":{"input":0,"output":0,"cache_read":0,"cache_write":0}}' > "$d/legion-router/config/costs.json"
  printf '%s\n' '{"title":"legion.span.v1"}' > "$d/legion-observability/schema/legion.span.v1.schema.json"
  printf -- '---\nname: p\ndescription: >\n  Multi line description body that line-based readers collapse.\n---\nbody\n' > "$d/p/SKILL.md"
  git -C "$d" add -A; git -C "$d" commit -q -m init
  BARE="$BATS_TEST_TMPDIR/bare.git"; git init -q --bare "$BARE"
  git -C "$d" remote add origin "$BARE"; git -C "$d" push -q origin main
}

# delegate stub: `run` performs the real fix (flatten block scalars); `review` approves.
_mk_delegate() {
  cat > "$STUB/delegate" <<'EOF'
#!/usr/bin/env bash
sub="$1"; shift; repo=""
while [ $# -gt 0 ]; do case "$1" in --repo) repo="$2"; shift 2;; *) shift;; esac; done
case "$sub" in
  run)
    while IFS= read -r f; do
      printf -- '---\nname: p\ndescription: Fixed single-line description.\n---\nbody\n' > "$f"
    done < <(find "$repo" -name SKILL.md)
    echo '{"status":"ok","run_id":"t","diff_path":"x"}' ;;
  review) echo '{"approve":true,"summary":"looks correct"}' ;;
esac
EOF
  chmod +x "$STUB/delegate"
}

# delegate stub whose `run` does NOT fix the defect (gate must reject it).
_mk_delegate_noop() {
  printf '#!/usr/bin/env bash\ncase "$1" in run) echo "{\\"status\\":\\"ok\\"}";; review) echo "{\\"approve\\":true}";; esac\n' > "$STUB/delegate"
  chmod +x "$STUB/delegate"
}

_mk_gh() {  # $1 = pr-list payload (default empty array)
  local list="${1:-[]}"
  cat > "$STUB/gh" <<EOF
#!/usr/bin/env bash
echo "\$@" >> "$GH_LOG"
if [ "\$1" = pr ] && [ "\$2" = list ]; then echo '$list'; exit 0; fi
if [ "\$1" = pr ] && [ "\$2" = create ]; then echo "https://example/pr/1"; exit 0; fi
exit 0
EOF
  chmod +x "$STUB/gh"
}

@test "heal plan: a block-scalar description is reported as auto-fixable" {
  run bash "$HEAL" plan --repo "$REPO"
  [[ "$output" == *"[fixable] descriptions"* ]]
}

@test "heal run --dry-run: plans but creates no branch and never delegates" {
  _mk_delegate; _mk_gh
  LEGION_DELEGATE_BIN="$STUB/delegate" GH_BIN="$STUB/gh" \
    run bash "$HEAL" run --repo "$REPO" --dry-run
  [[ "$output" == *"dry-run"* ]]
  # no heal branch was created, gh never called
  run git -C "$REPO" branch --list 'legion-heal/*'
  [ -z "$output" ]
  [ ! -f "$GH_LOG" ]
}

@test "heal run: heals the defect, pushes a branch, opens a PR, never merges" {
  _mk_delegate; _mk_gh
  LEGION_DELEGATE_BIN="$STUB/delegate" GH_BIN="$STUB/gh" BATS_BIN=true \
    run bash "$HEAL" run --repo "$REPO" --max 5
  [ "$status" -eq 0 ]
  # PR was created…
  grep -q "pr create" "$GH_LOG"
  grep -q "fix(heal): descriptions" "$GH_LOG"
  # …and a deterministic heal branch was pushed to the remote
  run git -C "$REPO" ls-remote --heads origin 'legion-heal/descriptions-*'
  [ -n "$output" ]
  # NEVER merges
  ! grep -q "pr merge" "$GH_LOG"
}

@test "heal run: gate rejects a fix that does not resolve the finding (no PR)" {
  _mk_delegate_noop; _mk_gh
  LEGION_DELEGATE_BIN="$STUB/delegate" GH_BIN="$STUB/gh" BATS_BIN=true \
    run bash "$HEAL" run --repo "$REPO" --max 5
  # no change → "produced no change" path → no PR create
  ! grep -q "pr create" "$GH_LOG" 2>/dev/null || true
  [ ! -f "$GH_LOG" ] || ! grep -q "pr create" "$GH_LOG"
}

@test "heal run: never commits legion runtime state (.legion/) into the PR branch" {
  # Delegate fixes the description AND drops a .legion/.gitignore (as the real
  # delegate.sh does). A .gitignore can't ignore itself, so without the reset
  # guard `git add -A` would stage it into the heal PR.
  cat > "$STUB/delegate" <<'EOF'
#!/usr/bin/env bash
sub="$1"; shift; repo=""
while [ $# -gt 0 ]; do case "$1" in --repo) repo="$2"; shift 2;; *) shift;; esac; done
case "$sub" in
  run)
    mkdir -p "$repo/.legion"; printf '*\n' > "$repo/.legion/.gitignore"
    while IFS= read -r f; do
      printf -- '---\nname: p\ndescription: Fixed single-line description.\n---\nbody\n' > "$f"
    done < <(find "$repo" -name SKILL.md)
    echo '{"status":"ok"}' ;;
  review) echo '{"approve":true}' ;;
esac
EOF
  chmod +x "$STUB/delegate"
  _mk_gh

  LEGION_DELEGATE_BIN="$STUB/delegate" GH_BIN="$STUB/gh" BATS_BIN=true \
    run bash "$HEAL" run --repo "$REPO" --max 5
  [ "$status" -eq 0 ]
  branch="$(git -C "$REPO" for-each-ref --format='%(refname:short)' 'refs/heads/legion-heal/descriptions-*' | head -1)"
  [ -n "$branch" ]
  run git -C "$REPO" ls-tree -r --name-only "$branch"
  ! grep -q '\.legion' <<<"$output"
}

@test "heal run: rejects a costs 'fix' that just deletes the artifact (gate guard)" {
  # Repair the block-scalar description so `costs` is the only FAIL finding, then
  # corrupt costs.json so doctor reports it.
  printf -- '---\nname: p\ndescription: Valid single line description.\n---\nbody\n' > "$REPO/p/SKILL.md"
  printf '%s\n' '{}' > "$REPO/legion-router/config/costs.json"
  git -C "$REPO" commit -aqm "only costs broken"; git -C "$REPO" push -q origin main

  # delegate stub whose `run` "fixes" the finding by DELETING the file — which
  # would flip the doctor check from FAIL to WARN (absent) and slip past --only.
  cat > "$STUB/delegate" <<'EOF'
#!/usr/bin/env bash
sub="$1"; shift; repo=""
while [ $# -gt 0 ]; do case "$1" in --repo) repo="$2"; shift 2;; *) shift;; esac; done
case "$sub" in
  run) rm -f "$repo/legion-router/config/costs.json"; echo '{"status":"ok"}' ;;
  review) echo '{"approve":true}' ;;
esac
EOF
  chmod +x "$STUB/delegate"
  _mk_gh

  LEGION_DELEGATE_BIN="$STUB/delegate" GH_BIN="$STUB/gh" BATS_BIN=true \
    run bash "$HEAL" run --repo "$REPO" --max 5
  [[ "$output" == *"deleting its artifact"* ]]
  [ ! -f "$GH_LOG" ] || ! grep -q "pr create" "$GH_LOG"
  # No heal branch reached the remote
  run git -C "$REPO" ls-remote --heads origin 'legion-heal/costs-*'
  [ -z "$output" ]
}

@test "heal run: idempotent — skips a finding that already has an open PR" {
  _mk_delegate; _mk_gh '[{"number":7}]'
  LEGION_DELEGATE_BIN="$STUB/delegate" GH_BIN="$STUB/gh" BATS_BIN=true \
    run bash "$HEAL" run --repo "$REPO" --max 5
  [[ "$output" == *"skip (PR already open)"* ]]
  ! grep -q "pr create" "$GH_LOG"
}

@test "heal run: --no-pr commits the fix locally without pushing" {
  _mk_delegate; _mk_gh
  LEGION_DELEGATE_BIN="$STUB/delegate" GH_BIN="$STUB/gh" BATS_BIN=true \
    run bash "$HEAL" run --repo "$REPO" --no-pr --max 5
  [ ! -f "$GH_LOG" ] || ! grep -q "pr create" "$GH_LOG"
  run git -C "$REPO" ls-remote --heads origin 'legion-heal/descriptions-*'
  [ -z "$output" ]
}
