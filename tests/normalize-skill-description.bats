#!/usr/bin/env bats
# normalize-skill-description.awk — flattens YAML block-scalar `description:`
# (`>` / `|`) in SKILL.md frontmatter to a single quoted line, so line-based
# frontmatter readers (Cursor bridge, some skill loaders) no longer capture
# just ">"/"|" and blank the description.

setup() {
  REAL="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  AWK="$REAL/scripts/lib/normalize-skill-description.awk"
}

# Emulate the Cursor bridge's line-based parser: read `description:` off one line.
_bridge_desc() {
  awk '
    /^---[ \t]*$/ { f++; next }
    f==1 && /^description:/ { sub(/^description:[ \t]*/,""); gsub(/^"|"$/,""); print; exit }
  ' "$1"
}

@test "normalize: folded (>) description collapses to one full line" {
  f="$BATS_TEST_TMPDIR/folded.md"
  printf -- '---\nname: x\ndescription: >\n  First clause here.\n  Second clause here.\n---\nbody\n' > "$f"
  awk -f "$AWK" "$f" > "$f.out"
  run _bridge_desc "$f.out"
  [[ "$output" == *"First clause here. Second clause here."* ]]
  [[ "$output" != ">" ]]
}

@test "normalize: literal (|) description collapses too" {
  f="$BATS_TEST_TMPDIR/literal.md"
  printf -- '---\nname: x\ndescription: |\n  Line one.\n  Line two.\n---\n' > "$f"
  awk -f "$AWK" "$f" > "$f.out"
  run _bridge_desc "$f.out"
  [[ "$output" == *"Line one. Line two."* ]]
}

@test "normalize: sibling keys after the block are preserved" {
  f="$BATS_TEST_TMPDIR/sibling.md"
  printf -- '---\nname: x\ndescription: >\n  Some text.\nmetadata:\n  version: 1.2.3\n---\n' > "$f"
  awk -f "$AWK" "$f" > "$f.out"
  grep -q '^metadata:' "$f.out"
  grep -q '  version: 1.2.3' "$f.out"
}

@test "normalize: embedded quotes are escaped (valid YAML \"...\" scalar)" {
  f="$BATS_TEST_TMPDIR/quotes.md"
  printf -- '---\nname: x\ndescription: >\n  Say "hello" now.\n---\n' > "$f"
  awk -f "$AWK" "$f" > "$f.out"
  grep -q 'description: "Say \\"hello\\" now."' "$f.out"
}

@test "normalize: a single-line description is left untouched (idempotent)" {
  f="$BATS_TEST_TMPDIR/plain.md"
  printf -- '---\nname: x\ndescription: Already one line.\n---\nbody\n' > "$f"
  awk -f "$AWK" "$f" > "$f.out"
  run diff "$f" "$f.out"
  [ "$status" -eq 0 ]
}

@test "normalize: body content is untouched" {
  f="$BATS_TEST_TMPDIR/body.md"
  printf -- '---\nname: x\ndescription: >\n  Text.\n---\n# Heading\n\ndescription: > not frontmatter\n' > "$f"
  awk -f "$AWK" "$f" > "$f.out"
  grep -q '^# Heading' "$f.out"
  grep -q '^description: > not frontmatter' "$f.out"
}
