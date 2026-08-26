---
name: legion-orchestrate
kind: procedure
# disable-model-invocation intentionally false: cross-harness orchestrator entrypoint
description: Use to deliver a multi-step goal with Legion's dynamic multi-model orchestration. Decompose the goal, fan out scoped slices to configured executors, retain evidence, cross-model verify where available, synthesize, and gate. Today's executor adapters are coding-focused. Triggers on "orchestrate with legion", "fan out", "ultracode", "build this with legion", parallel multi-model delivery, or any sizeable feature/refactor.
---

# Legion Orchestrate: dynamic multi-model execution

The Claude "ultracode" loop (decompose → fan out → adversarially verify → synthesize → gate), but **executor-aware**: the active primary conducts, configured harnesses handle work that fits their strengths, and an independent reviewer provides the final judgement. Every handoff is metered.

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

Do not manually replay this lifecycle after a terminal runner receipt. Return
to the primary session and record a `legion-converge` checkpoint. Continue only
for new source or failure evidence; yield on `complete`, `waiting_external`, or
`blocked`.

1. **Decompose** (Opus) — break the goal into **dependency-aware slices**. Independent slices can run in parallel; dependent ones are sequenced.
2. **Classify** — tag each slice with a routing archetype (`legion-route --list`): implementation → `implement-feature`/`write-tests`/`fix-bug`/`refactor-module`/… (configured Codex workhorse); genuine design/judgement → `deep-reasoning`/`architecture-decision` (stays on Claude).
3. **Fan out** (parallel) — write the independent slices as JSONL and run them at once:
   ```bash
   legion-fanout --slices slices.jsonl --repo . --max-concurrency 4
   #   {"archetype":"implement-feature","task":"...self-contained spec..."}
   ```
   Delegated slices run in parallel worktrees; `self` slices come back
   `status:"inline"` for the active primary. The returned `task_ledger_path`
   is the durable proof of which queued slices started, which were blocked
   before launch, and how every slice terminated.
4. **Cross-model verify** (independent reviewer) — for each returned diff, get an independent structured verdict:
   ```bash
   legion-run resolves `final-review` through its configured executor; do not
   substitute the `legion-delegate review` command for that archetype.
   ```
   Review is pinned to the immutable base/head SHAs recorded in
   `review-input.json`; reconcile its findings against your own. **Always get
   the configured reviewer sign-off before merge.**
5. **Synthesize** (Claude) — apply the verified diffs (`legion-delegate apply --run <id>`), resolve conflicts, integrate.
6. **Gate** — run `/review-gate` (or `/opus-commands:ultra-review` for big diffs) before done.

## Ultracode mode — `LEGION_ULTRACODE=1`

Go maximally exhaustive:
- **More parallelism** — decompose finer; fan out widely (`--max-concurrency` up).
- **Multi-vote verify** — a diff is accepted only if **the independent reviewer and the primary engineer** both approve (run `final-review` + your own review; disagreement → `cross-model-tiebreak`).
- **Loop-until-dry** — re-run review fan-out until two consecutive passes surface nothing new.
- Everything metered; use `legion-share` when the configured work-split preference is useful.

## Configurable work-share preference

- The Codex share target defaults to `0.5`, but it is advisory unless a repository explicitly runs `legion-share gate`.
- Configure it in `routing.toml [targets].codex_share`, with `LEGION_TARGET_CODEX_SHARE`, or per command via `--target`.
- `legion-share next` is a recommendation; task fit and user intent take precedence.
- **Log your own slices** so the split has a denominator: `legion-trace emit --executor opus --model "$(legion-route --model-ref claude_orchestrator)" --status ok`.
- `legion-share` shows the live ratio against the configured preference.

## Verify every delegated diff

A delegated diff is a PR from an unfamiliar contributor — read it, run typecheck/tests, *then* `apply`. Never blind-merge. The fan-out returns each slice's `diff_path`, `status`, `cost_usd`, and `model`.
