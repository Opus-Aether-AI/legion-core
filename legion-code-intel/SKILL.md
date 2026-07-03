---
name: legion-code-intel
kind: ability
description: Optional Legion code-intelligence diagnostics: run repo-native TypeScript/Pyright checks, filter changed-file findings, and emit metered Legion artifacts/spans.
---

Use this skill when a task needs static code-intelligence signals before or after
agent edits: TypeScript/Python diagnostics, changed-file diagnostic gates,
benchmarks for whether diagnostics catch failures earlier, or an LSP/code-intel
roadmap discussion.

Prefer the CLI over ad hoc commands:

```bash
legion-code-intel diagnostics --repo . --adapter auto --changed-only --emit-span --json
```

Interpretation:

- `status=ok`: adapters ran and no error diagnostics were found.
- `status=failed`: at least one error diagnostic was found; treat this as a
  pre-PR gate failure.
- `status=skipped`: no supported adapter was available/detected; this is not a
  repo failure.
- `status=error`: the adapter itself failed unexpectedly or timed out.

Keep claims precise: this plugin is code-intelligence/LSP-ready infrastructure,
not proof that legion-core has full language-server lifecycle management for 50+
languages. It currently uses repo-native diagnostic adapters because they are
deterministic, cheap, and safe to run in isolated Legion worktrees.
