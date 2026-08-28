---
name: legion-deepseek-mode
kind: ability
description: The routing guide for a DeepSeek Harness-primary Legion session. Use when DeepSeek Harness is driving work, when deciding whether a bounded unit should stay inline or use the configured role for an archetype, or when the user asks to use Legion from DeepSeek Harness, get a second opinion, review a DeepSeek change, or delegate from DeepSeek Harness.
---

# Legion — DeepSeek Harness mode

You are running DeepSeek Harness as the active Legion primary. Keep bounded work
inline when you have the required context. For independent implementation or a
second perspective, use the configured role for the relevant archetype; no
harness is the default on-call secondary.

## DeepSeek Harness limits

DeepSeek Harness is a `primary coding` executor, but do not overstate its
adapter contract:

- **No `run` subcommand.** Headless execution is a profile boot:
  `dsh --profile <name> <task>`.
- **No supplied headless profile.** `dsh` ships no headless preset. Author a
  profile that loads the headless application and set `LEGION_DSH_PROFILE` to
  that profile name. Without it, the DeepSeek executor is unavailable.
- **No review capability.** `executors.toml` declares `review = "none"`.
  DeepSeek cannot emit a schema-valid review verdict and is not in the review
  fallback order. Use an archetype with a configured review role instead.
- **Usage is not metered.** `dsh` publishes no headless output contract for
  tokens or cost. Legion reports both as zero meaning **not reported**; it does
  not imply free or zero usage.

The isolated worktree and diff remain the deliverable for delegated DeepSeek
work. Read-only requests are checked after execution because dsh has no
documented headless flag that disables write tools.

## Route by archetype and role

| Need | Archetype | Current role | Decision |
|---|---|---|---|
| Bounded implementation with enough context | `self` | `self` | Keep it with the active DeepSeek Harness primary. |
| Bounded implementation / mechanical edit | `implement-feature` / `bulk-mechanical-edit` | `codex_workhorse` | Use the configured implementation route when a separate worker is useful. |
| Architecture / high-judgement decision | `architecture-decision` / `deep-reasoning` | `self` | Keep primary-owned judgement inline. |
| Final merge judgement | `final-review` | `claude_default` | Use the current configured review route. |
| Different-lineage opinion | `second-opinion-review` | `cursor_default` | Use when a distinct perspective matters. |
| Structured security review | `security-review` | `codex_review` | Do not send this to DeepSeek: it cannot review. |

The mapping is a current configuration fact from `routing.toml`,
`executors.toml`, and `models.toml`. Inspect `legion-route --list` and
`legion-route --list-executors` in the installed runtime before relying on it.

## Delegate through Legion

```bash
# Let the configured implementation archetype select its executor and role.
legion-delegate run --archetype implement-feature --task "Build X per <spec>" --repo . --apply

# Ask the configured final-review role to evaluate an immutable diff.
legion-delegate review --archetype final-review --base origin/main --head HEAD --repo .

# Run DeepSeek explicitly only when intentionally overriding policy.
legion-delegate run --executor deepseek --task "Make this bounded change in <file>" --repo .
```

Give a delegate a self-contained brief: target files, required behavior,
acceptance checks, and the smallest permitted scope. Inspect its result and
diff before applying it. Do not replace the Legion command with a raw provider
call: that would bypass worktree isolation and evidence capture.

Set `LEGION_PRIMARY=deepseek` in the environment that starts delegations so
Legion attributes the orchestration correctly. Use `legion-doctor --only
deepseek` to verify that `dsh` and the named `LEGION_DSH_PROFILE` are usable.

## Convergence

For a substantial inline workflow, record each material checkpoint with
`legion-converge --checkpoint <file> --repo . --json`. Continue only when it
returns `actionable` with changed source or failure evidence. Yield on
`complete`, `waiting_external`, or `blocked`; an external state change can
resume `waiting_external`. Never rerun validation on an unchanged tree or
review the same immutable head merely to keep the primary turn alive.
