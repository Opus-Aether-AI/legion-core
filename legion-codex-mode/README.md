# legion-codex-mode

The **Codex-primary** routing brain for Legion — the mirror image of [`legion-router`](../legion-router)
(which is the Claude-primary brain).

When you run Legion under **Codex CLI**, you (GPT-5.5) are the primary and do most of the
work. This skill tells you the few cases where it's worth handing a task **up to Claude**
via [`legion-claude`](../legion-router/scripts/legion-claude.sh):

- deep architecture / system design,
- **polished or complex frontend** (Opus + the `impeccable` skill is the best combo),
- final adversarial / cross-model review of your own diff,
- tie-breaks between plausible designs,
- when you're stuck after a couple honest attempts.

`legion-claude` is **metered** and **auto-falls-back to GPT-5.5** when the Claude usage
limit is hit, so reaching for Claude never blocks you.

It also maps what already works natively on Codex after `legion-setup codex` — registered
MCPs, the mirrored skill set, and the bridged `legion-cmd-*` / `legion-agent-*` skills — so
you don't reach for Claude when the capability is already at your fingertips.

## Setup

```bash
legion-setup codex          # wire MCPs + skills + bridged commands/agents into Codex
legion-setup codex verify   # readiness check
```

See [`SKILL.md`](./SKILL.md) for the full decision guide.
