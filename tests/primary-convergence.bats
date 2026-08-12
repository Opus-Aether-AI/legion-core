#!/usr/bin/env bats

setup() {
  ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
}

@test "every primary harness points to the convergence contract" {
  for skill in \
    legion-codex-mode/SKILL.md \
    legion-opencode-mode/SKILL.md \
    legion-hermes-mode/SKILL.md \
    legion-pi-mode/SKILL.md \
    legion-router/SKILL.md
  do
    grep -Fq 'legion-converge' "$ROOT/$skill"
    grep -Fq 'waiting_external' "$ROOT/$skill"
  done
}

@test "heavy-task skills prohibit manually replaying the lifecycle" {
  grep -Fq 'Do not manually replay' "$ROOT/legion-run/SKILL.md"
  grep -Fq 'Do not manually replay' "$ROOT/legion-orchestrate/SKILL.md"
}

@test "codex work share is configurable and not a hard workflow rule" {
  grep -Fq 'codex_share = 0.5' "$ROOT/legion-router/config/routing.toml"
  grep -Fq 'LEGION_TARGET_CODEX_SHARE' "$ROOT/legion-router/SKILL.md"
  grep -Fq 'advisory' "$ROOT/legion-orchestrate/SKILL.md"
  ! grep -Eq '≥50%|codex should do \*\*≥50%' "$ROOT/legion-router/SKILL.md" "$ROOT/legion-orchestrate/SKILL.md"
}
