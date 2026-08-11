---
name: legion-pi-mode
kind: ability
description: The routing guide for a Pi-primary Legion session. Use when Pi is driving coding work, when deciding whether a bounded task needs an independent harness, or when the user asks to use Legion from Pi, get a second opinion, review a Pi change, or delegate from Pi.
---

# Legion — Pi mode

You are **Pi**, the active Legion primary. Keep bounded work inline when you have
enough context; use a different registered coding family when independent
implementation, review, or a second perspective materially improves confidence.
Set `LEGION_PRIMARY=pi` in the session environment; automatic Pi detection is a
best-effort fallback.

```bash
# Let the configured archetype choose a coding executor:
legion-delegate run --archetype implement-feature --task "Build X per <spec>" --repo .

# Make one explicit cross-family handoff:
legion-delegate run --executor codex --task "Implement the bounded fix in <file>" --repo .
legion-delegate run --executor claude --task "Review this design and recommend one option" --repo .
legion-delegate run --executor cursor --archetype final-review \
  --task "Review the committed diff origin/main...HEAD; report only actionable findings and do not edit files." \
  --base HEAD --repo .
```

Use `legion-route --list-executors` to see the registered families. A delegated
worker may hand off once only through `legion-delegate run --executor
<different-harness>`; same-family recursion and the depth limit are rejected.

Give every delegate a standalone brief: target files, required behavior,
acceptance checks, and the smallest permitted scope. Inspect its result or diff
before applying it. The adapter creates an isolated worktree and emits a metered
span, so do not replace it with an untracked raw provider call.

For Pi readiness, run `legion-setup pi verify`. Pi discovers this guidance from
`~/.agents/skills/legion-pi-mode` after the idempotent Legion installer runs.
