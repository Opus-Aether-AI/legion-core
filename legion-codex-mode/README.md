# legion-codex-mode

The **Codex-primary** routing guide for Legion. Legion's execution contract is
model-agnostic: route a scoped unit to a capable executor, isolate it, retain
evidence, meter it, and learn from the outcome. Coding is the current executor
application; this guide explains Codex's role within it.

When you run Legion under **Codex CLI**, Codex is the active primary. This
skill tells you when to keep work inline and when to use the configured role
for an archetype:

- `self` for primary-owned judgement,
- `claude_opus` for the current `frontend-polish` route,
- `claude_default` for the current `final-review` route,
- `codex_review` or `cursor_default` where their review archetypes apply.

Those role mappings are current configuration facts, not an architectural
preference for any harness. Use `legion-route --list` to inspect the policy
installed with the runtime.

It also maps what already works natively on Codex after `legion-setup codex`:
registered MCPs, the mirrored skill set, and the bridged `legion-cmd-*` /
`legion-agent-*` skills.

## Setup

```bash
legion-setup codex          # wire MCPs + skills + bridged commands/agents into Codex
legion-setup codex verify   # readiness check
```

See [`SKILL.md`](./SKILL.md) for the full decision guide.
