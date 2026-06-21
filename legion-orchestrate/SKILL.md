---
name: legion-orchestrate
description: Use to deliver a multi-step coding goal with Legion's dynamic MULTI-MODEL orchestration — decompose the goal, fan out implementation slices to GPT-5.4 in PARALLEL, cross-model verify with GPT-5.5, synthesize, and gate. The multi-model version of ultracode/Workflow orchestration. Triggers on "orchestrate with legion", "fan out", "ultracode", "build this with legion", parallel multi-model delivery, or any sizeable feature/refactor you want delivered with codex doing the bulk.
---

# Legion Orchestrate — dynamic multi-model delivery (ultracode for a legion of models)

The Claude "ultracode" loop (decompose → fan out → adversarially verify → synthesize → gate), but **executor-aware**: Opus conducts, **GPT-5.4 does the bulk of coding in parallel**, **GPT-5.5 verifies**, all metered and kept at ≥50% codex ([[project_legion_marketplace]]).

## The loop

1. **Decompose** (Opus) — break the goal into **dependency-aware slices**. Independent slices can run in parallel; dependent ones are sequenced.
2. **Classify** — tag each slice with a routing archetype (`legion-route --list`): implementation → `implement-feature`/`write-tests`/`fix-bug`/`refactor-module`/… (GPT-5.4); genuine design/judgement → `deep-reasoning`/`architecture-decision` (stays on Opus).
3. **Fan out** (parallel) — write the independent slices as JSONL and run them at once:
   ```bash
   legion-fanout --slices slices.jsonl --repo . --max-concurrency 4
   #   {"archetype":"implement-feature","task":"...self-contained spec..."}
   ```
   GPT-5.4 slices run in parallel worktrees; `self` slices come back `status:"inline"` for you to do. You stay free to coordinate.
4. **Cross-model verify** (GPT-5.5) — for each returned diff, get an independent structured verdict:
   ```bash
   legion-delegate review --archetype final-review --base <branch>   # gpt-5.5, schema verdict
   ```
   Reconcile its findings against your own. **Always get 5.5's sign-off before merge.**
5. **Synthesize** (Opus) — apply the verified diffs (`legion-delegate apply --run <id>`), resolve conflicts, integrate.
6. **Gate** — run `/review-gate` (or `/opus-commands:ultra-review` for big diffs) before done.

## Ultracode mode — `LEGION_ULTRACODE=1`

Go maximally exhaustive:
- **More parallelism** — decompose finer; fan out widely (`--max-concurrency` up).
- **Multi-vote verify** — a diff is accepted only if **GPT-5.5 *and* Opus** both approve (run `final-review` + your own review; disagreement → `cross-model-tiebreak`).
- **Loop-until-dry** — re-run review fan-out until two consecutive passes surface nothing new.
- Everything metered; check `legion-share` to confirm codex carried ≥50%.

## Keep it honest (the ≥50% controller)

- Before doing an eligible implementation slice **yourself**, check `legion-share next` — if it says `codex`, delegate it.
- **Log your own slices** so the split has a denominator: `legion-trace emit --executor opus --model opus --status ok`.
- `legion-share` shows the live ratio; aim to keep codex (5.4 + 5.5) ≥ target.

## Verify every delegated diff

A delegated diff is a PR from an unfamiliar contributor — read it, run typecheck/tests, *then* `apply`. Never blind-merge. The fan-out returns each slice's `diff_path`, `status`, `cost_usd`, and `model`.
