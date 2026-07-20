---
name: legion-orchestrate
kind: procedure
# disable-model-invocation intentionally false: cross-harness orchestrator entrypoint
description: Use to deliver a multi-step coding goal with Legion's dynamic multi-model orchestration — decompose the goal, fan out implementation slices to the configured Codex workhorse in parallel, cross-model verify with the independent Fable reviewer, synthesize, and gate. The multi-model version of ultracode/Workflow orchestration. Triggers on "orchestrate with legion", "fan out", "ultracode", "build this with legion", parallel multi-model delivery, or any sizeable feature/refactor you want delivered with codex doing the bulk.
---

# Legion Orchestrate — dynamic multi-model delivery (ultracode for a legion of models)

The Claude "ultracode" loop (decompose → fan out → adversarially verify → synthesize → gate), but **executor-aware**: Claude conducts, the configured Codex workhorse does the bulk of coding in parallel, and Fable provides the independent final judgement, all metered and kept at ≥50% codex ([[project_legion_marketplace]]).

## Preflight

Before decomposing, run a bounded install check:

```bash
legion-self-learn hints --entity skill:legion-orchestrate
legion-doctor --only codex
legion-doctor --only router
```

Treat the self-learning hints as workflow guardrails for this run. They are the
durable memory from prior failures and reviews; do not mine broad session logs
here unless the user explicitly asks Legion to learn from past sessions.

Router failure is only blocking when the current Claude process or
`~/.claude/settings.json` forces `ANTHROPIC_BASE_URL` to the local `:8082`
proxy. If it fails in that mode, remove the global proxy env or start/fix
`legion-router` before orchestration; otherwise Claude API calls can fail before
fan-out even begins. Do not run broad session/log greps as preflight.

## The loop

For any sizeable task that needs the full proof loop, prefer `legion-run` over
manually composing the lower-level commands. Use direct mode for one-off heavy
work:

```bash
legion-run --repo . --task "..." --plan-file ./PLAN.md --plan-file ./ARCHITECTURE.md --validate-command "npm test && npm run build && printf '{\"ok\":true}\\n'" --json
```

Use plugin mode when the plan/validate/evaluate commands are reusable domain
logic:

```bash
legion-run --plugin-manifest <plugin>/legion-plugin.toml --repo . --task "..."
```

That runner enforces `legion.heavy_task.v1`: doctor, self-learn hints, plan,
route, fan-out/apply, final review, validation, evaluation, observability HTML,
share accounting, self-learn, and heal planning. Existing
`legion.full_app.v1` plugins are still accepted. Drop to `legion-fanout` only
when you are debugging the primitive, running small independent slices, or
building a new runner profile.

1. **Decompose** (Opus) — break the goal into **dependency-aware slices**. Independent slices can run in parallel; dependent ones are sequenced.
2. **Classify** — tag each slice with a routing archetype (`legion-route --list`): implementation → `implement-feature`/`write-tests`/`fix-bug`/`refactor-module`/… (configured Codex workhorse); genuine design/judgement → `deep-reasoning`/`architecture-decision` (stays on Claude).
3. **Fan out** (parallel) — write the independent slices as JSONL and run them at once:
   ```bash
   legion-fanout --slices slices.jsonl --repo . --max-concurrency 4
   #   {"archetype":"implement-feature","task":"...self-contained spec..."}
   ```
   Codex slices run in parallel worktrees; `self` slices come back `status:"inline"` for you to do. You stay free to coordinate.
4. **Cross-model verify** (independent Fable reviewer) — for each returned diff, get an independent structured verdict:
   ```bash
   legion-run resolves `final-review` through its configured executor; do not
   invoke the Codex-only `legion-delegate review` command for that archetype.
   ```
   Reconcile its findings against your own. **Always get the configured reviewer sign-off before merge.**
5. **Synthesize** (Claude) — apply the verified diffs (`legion-delegate apply --run <id>`), resolve conflicts, integrate.
6. **Gate** — run `/review-gate` (or `/opus-commands:ultra-review` for big diffs) before done.

## Ultracode mode — `LEGION_ULTRACODE=1`

Go maximally exhaustive:
- **More parallelism** — decompose finer; fan out widely (`--max-concurrency` up).
- **Multi-vote verify** — a diff is accepted only if **the independent Fable reviewer and the primary engineer** both approve (run `final-review` + your own review; disagreement → `cross-model-tiebreak`).
- **Loop-until-dry** — re-run review fan-out until two consecutive passes surface nothing new.
- Everything metered; check `legion-share` to confirm codex carried ≥50%.

## Keep it honest (the ≥50% controller)

- Before doing an eligible implementation slice **yourself**, check `legion-share next` — if it says `codex`, delegate it.
- **Log your own slices** so the split has a denominator: `legion-trace emit --executor opus --model "$(legion-route --model-ref claude_orchestrator)" --status ok`.
- `legion-share` shows the live ratio; aim to keep codex ≥ target.

## Verify every delegated diff

A delegated diff is a PR from an unfamiliar contributor — read it, run typecheck/tests, *then* `apply`. Never blind-merge. The fan-out returns each slice's `diff_path`, `status`, `cost_usd`, and `model`.
