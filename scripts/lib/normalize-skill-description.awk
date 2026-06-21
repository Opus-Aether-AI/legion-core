#!/usr/bin/env awk -f
# normalize-skill-description.awk — flatten a YAML block-scalar `description:`
# in a SKILL.md frontmatter into a single-line double-quoted scalar.
#
# Why: several harnesses + line-based frontmatter readers (e.g. the Legion
# Cursor bridge, and some skill loaders) read `description:` from a single line.
# When an upstream ships `description: >` / `description: |` with the text on the
# following indented lines, those readers capture just ">"/"|" and the real
# description is lost — the skill shows a blank/garbage description and stops
# auto-triggering. We collapse the block into one quoted line on vendor import so
# every consumer sees the full text. Idempotent: a non-block description passes
# through untouched.
#
# Reads one SKILL.md on stdin, writes the normalized file to stdout.

function flush_block(   collapsed) {
  collapsed = _buf
  gsub(/[ \t\r\n]+/, " ", collapsed)        # collapse all whitespace to one space
  sub(/^ /, "", collapsed); sub(/ $/, "", collapsed)
  gsub(/\\/, "\\\\", collapsed)              # escape backslashes …
  gsub(/"/, "\\\"", collapsed)               # … and double-quotes for a YAML "…" scalar
  printf "%s%s: \"%s\"\n", _indent, _key, collapsed
  capturing = 0; _buf = ""
}

BEGIN { in_fm = 0; fm_seen = 0; capturing = 0; _buf = "" }

{
  # Track the frontmatter fences (first two lines that are exactly ---).
  if (!fm_seen && $0 ~ /^---[ \t]*$/) { fm_seen = 1; in_fm = 1; print; next }
  else if (in_fm && $0 ~ /^---[ \t]*$/) {
    if (capturing) flush_block()
    in_fm = 0; print; next
  }

  if (in_fm && !capturing && $0 ~ /^[ \t]*description:[ \t]*[>|][+-]?[ \t]*$/) {
    # Start of a block-scalar description. Remember its indent + key.
    match($0, /^[ \t]*/); _indent = substr($0, 1, RLENGTH)
    _key = "description"; _key_indent = length(_indent)
    capturing = 1; _buf = ""; next
  }

  if (capturing) {
    if ($0 ~ /^[ \t]*$/) { _buf = _buf " "; next }     # blank line inside block
    match($0, /^[ \t]*/); this_indent = RLENGTH
    if (this_indent > _key_indent) {                    # still inside the block
      line = $0; sub(/^[ \t]+/, "", line)
      _buf = _buf " " line; next
    }
    flush_block()                                         # dedented → block ended
    # fall through to print the current (sibling key / fence) line normally
  }

  print
}

END { if (capturing) flush_block() }
