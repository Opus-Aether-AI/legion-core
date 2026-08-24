---
name: legion-router
kind: ability
description: Use when a primary harness should hand a scoped task to a configured Codex, Claude, Cursor, opencode, Pi, or Hermes executor — implementation, independent code generation, cross-model review, second opinions, or tie-breaks. Drives Legion executor adapters in isolated worktrees with metered telemetry. For a whole multi-step goal, use legion-orchestrate.
---

# Legion Router — delegate to a legion of models

## Primary-session convergence

For a substantial inline workflow, record each material checkpoint with
`legion-converge --checkpoint <file> --repo . --json`. Continue only when it
returns `actionable` with changed source or failure evidence. Yield on
`complete`, `waiting_external`, or `blocked`; an external state change can
resume `waiting_external`. Never rerun validation on an unchanged tree or
review the same immutable head merely to keep the primary turn alive.

## Work split — balance by strength

Before changing routing behavior or running a high-leverage delegation workflow,
check learned harness guardrails when available:

```bash
legion-self-learn hints --entity plugin:legion-router
```

Legion is a team. Play each configured role to its strength:

- **Active primary = orchestrate** — plan, decompose, decide, verify, and
  integrate. The primary is the conductor, not automatically the bulk coder.
- **Configured executor roles = implementation + review** — route implementation,
  tests, refactors, bulk edits, migrations, and independent verification by
  archetype. Concrete model IDs resolve from `config/models.toml`.

The share target is an advisory routing preference, not a hard workflow rule.
It defaults to `0.5` in `routing.toml [targets].codex_share` and can be changed
in that config, with `LEGION_TARGET_CODEX_SHARE`, or per command with
`legion-share --target <0..1>`. Route by task fit even when that differs from
the target; use an explicit `legion-share gate` only when a repository chooses
to enforce its configured preference.

**Make it measurable (the controller loop):**
1. When you do a task **yourself**, log it: `legion-trace emit --executor opus --model "$(legion-route --model-ref claude_orchestrator)" --status ok` (so the split has a denominator).
2. Optionally check `legion-share next` for a recommendation before an eligible implementation task; task fit and user intent still win.
3. `legion-share` shows the live ratio + per-model breakdown against the configured target (default `0.5`).

So: delegate any independent, self-contained task through its configured Legion
route so the primary stays free to coordinate. Keep orchestration and genuine
judgement inline.

## The honest mechanism

`codex exec` is an **autonomous agent** (task → edits), not a chat endpoint. So GPT work does **not** flow through the :8082 HTTP proxy — it runs out-of-band via `legion-delegate`, which:

1. creates an **isolated git worktree** (no contamination of your tree),
2. runs `codex exec -m <model> -s <sandbox>` with the task piped via **stdin** (injection-safe),
3. captures the **diff** + last message + **token usage**,
4. prices it via the shared cost table and emits a `legion.span.v1` **telemetry span**,
5. best-effort POSTs usage to the router **/ingest** sink so GPT cost shows next to Claude.

You then **verify the diff** before applying it. Delegation never auto-applies unless you pass `--apply` and the verify gate is clean.

Cursor Agent uses the same sidecar pattern through `legion-cursor`: it runs Cursor's headless `agent -p --trust` in an isolated worktree, maps `--sandbox read-only` to Cursor plan mode, captures the diff/result, emits `executor:"cursor"` telemetry with the actual returned model when Cursor reports one, and leaves applying the patch to the orchestrator unless `--apply` is passed.

Pi uses its official JSON event stream: `legion-pi` runs `pi -p --mode json
--no-session`, requires a valid successful final settled `agent_end`, aggregates
usage and cost once from every assistant `message_end` and successful
`compaction_end`, and maps `model:thinking` or
`--thinking` onto Pi's explicit thinking flag. Its read-only adapter allowlists
only `read`, `grep`, `find`, and `ls` and refuses any patch.

Hermes uses `hermes --oneshot` with a Legion-owned `--usage-file`. Its
workspace-write runs strictly validate the whole JSON usage document and treat
stdout as opaque final text. Legion ignores the user's Hermes configuration and
pins the one-shot toolsets to `terminal,file`, while still loading repository
rules such as `AGENTS.md`; user plugins, hooks, MCPs, and cron/browser tools are
not part of the auto-approved run. Both providers run behind a host filesystem
and process boundary (`sandbox-exec` on macOS or Bubblewrap with a private PID
namespace on Linux) that permits writes only to the generated worktree, scrubbed
private credential/temp/cache paths, and exact provider stdout/stderr/usage
files. Host control sockets and installed delegate entrypoints are unavailable;
the authenticated broker shim is the sole child-harness path. Parent-owned
patches, results, telemetry, and an isolated Git index stay outside that
writable set. A descendant-aware supervisor reaps session/process-group
escapes; on macOS a distinct run-unique Seatbelt deny/allow fingerprint for the
provider and broker target also catches rapid double-forks after they shed
ancestry, environment, and descriptors, while excluding unrelated sandboxes.
Hermes currently has no
documented enforceable read-only one-shot mode, so that request fails before
launching the provider rather than weakening the sandbox.

## When to delegate (decision guide)

| Situation | Delegate? | How |
|---|---|---|
| Bulk mechanical edit across many files | ✅ yes | `run --archetype bulk-mechanical-edit` |
| Independent module/file you can spec fully | ✅ yes | `run` with a tight, stateless task description |
| Codex review of a risky diff / PR | ✅ yes | `review --archetype security-review --base <ref> [--head <ref>] [--task "bounded instructions"]` |
| Different-lineage second opinion | ✅ yes | route `second-opinion-review`, then use that executor's read-only adapter |
| Two designs both plausible (tie-break) | ✅ yes | `review` on each, compare verdicts |
| Task needs your conversation context / judgement | ❌ no | do it inline |
| Tiny edit you can do in one tool call | ❌ no | do it inline (delegation overhead isn't worth it) |
| Anything touching secrets / untrusted input with write access | ⚠️ caution | read-only sandbox, or refuse |

## Scoping a stateless task

The delegated agent starts fresh — **no access to this conversation**. Write the task as if briefing a new engineer: name the files, state the exact change, give the acceptance criteria, and say "make the minimal edit, no unrelated changes."

## Let Legion pick the model — `--archetype`

Prefer `--archetype` over a raw `--model`: the routing policy (`config/routing.toml`, resolved by `legion-route`) picks the approved model plus the right sandbox and reasoning effort. Run `legion-route --list` for the current set:

Run `legion-route --list` for the full set. Grouped by role:

| Role | Archetypes | → model |
|---|---|---|
| **Primary orchestrates (self)** | `orchestrate`, `architecture-decision`, `deep-reasoning` | active primary — **refuses to delegate** |
| **Codex execution path** | `scout`, `implement-feature`, `write-tests`, `fix-bug`, `refactor-module`, `bulk-mechanical-edit`, `parallel-codegen`, `cheap-bulk`, `docs-edit`, `boilerplate`, `migration`, `security-review`, `hard-bug`, `perf-optimization` | `codex_workhorse` / `codex_review` |
| **Independent merge judgement** | `final-review` | `claude_default` |

So: most coding and hard/critical execution → Codex roles from `models.toml`; final merge judgement → the independent Claude reviewer; orchestration → you keep it (delegating it is refused).

## Commands

```bash
# Auto-routed delegation (model/sandbox/effort from routing.toml):
legion-delegate run --archetype bulk-mechanical-edit \
  --task "In src/foo.ts add a null-guard to bar(); minimal edit only" --repo .

# Cursor Agent second implementation / editor-native opinion:
legion-cursor run --task "Try the same fix using Cursor Agent; minimal edit only" --repo .

# Pin a model/effort explicitly (overrides the archetype):
printf '%s' "$LONG_TASK" | legion-delegate run \
  --model "$(legion-route --model-ref codex_workhorse)" --reasoning-effort high --repo .

# Codex second pass → STRUCTURED verdict JSON you can reconcile:
legion-delegate review --archetype security-review --base main --head HEAD --repo . --task "Verify required guardrails."
#   -> {verdict: approve|request_changes|comment, summary, findings:[{severity,title,file,line,detail}]}
# Review refs are resolved once to immutable commits. Add `--head <ref>` when
# reviewing a non-HEAD snapshot; `--max-attempts N` bounds transient retries
# (default 2). Every launched review is explicitly read-only and writes a
# durable `terminal_receipt`; approve/comment cannot hide blocking findings.

# Iterate on a kept session (same codex thread) instead of starting fresh:
legion-delegate run    --archetype parallel-codegen --task "..." --repo . --keep   # note the run_id
legion-delegate resume --run <RUN_ID> --task "now also handle the empty case" --repo .

# Apply a verified diff, then clean up:
legion-delegate apply   --run <RUN_ID> --repo .
legion-delegate cleanup --run <RUN_ID> --repo .
```

Reasoning effort (via codex `-c model_reasoning_effort`) is chosen by archetype:
use `low`/`medium` for bounded investigation and mechanical work, `high` for a
scoped implementation, and `max` only for a declared hard or persistent slice.
Claude runs at `high` for intent, design, and final merge judgement. `review`
returns a schema-valid verdict from the first reachable reviewer in
`[review].order` (routing.toml); the final workflow review may also route to Claude for
independent simplification judgement.

## Credit / quota resilience (self-healing)

- **Auto-fallback:** if the chosen model hits a quota/rate-limit error, `run` automatically walks the archetype's `fallback` chain when one is configured and retries; a *non*-quota failure stops immediately (doesn't burn the chain).
- **Low-credit mode:** set `LEGION_LOW_CREDIT` to steer away from a depleted provider:
  - `LEGION_LOW_CREDIT=claude` → Claude is low: delegate *more* to the configured Codex workhorse, even normally-self tasks.
  - `LEGION_LOW_CREDIT=codex` (or `gpt`) → GPT is low: **refuse to delegate**, so Claude does it inline instead (`LEGION_FORCE_DELEGATE=1` overrides if you want to spend the last credits anyway).
- **Budget is advisory:** `--budget-tokens N` flags an over-budget run (`status: over_budget`) but still returns the usable diff and **exits 0** — codex can't be pre-empted mid-run, so budget never silently fails a good result.

## Worktree lifecycle

- `run` **auto-deletes** its worktree + branch on completion (artifacts under `runs/` are preserved). Pass `--keep` to retain it (required to `resume`).
- Bulk cleanup when you need it: `legion-delegate cleanup --all` (all worktrees + branches), add `--purge` to also drop `runs/` artifacts; or `cleanup --run <RUN_ID> [--purge]` for one.
- Cleanup removes only worktrees whose branch and parent-written ownership
  receipt agree. Retained Pi and Hermes worktrees use the same safe cleanup
  path; an unowned or mismatched directory is preserved.

## Verify the returned diff (always)

Read `diff_path`, sanity-check it does exactly what you asked and nothing else, then run the repo's typecheck/tests before `apply`. Treat a delegated diff like a PR from an unfamiliar contributor.

## Safety defaults

- `run` defaults to `workspace-write` (edits the worktree); `review` is `read-only`.
- `danger-full-access` is **hard-blocked** unless `LEGION_ALLOW_DANGER=1`.
- Task text is scanned for dangerous/injection patterns before runs and reviews (override: `LEGION_ALLOW_UNSAFE=1`).
- `executor=self` is returned to the primary for inline work. A delegated worker
  normally implements its assigned slice directly. It may make one explicit
  `legion-delegate run --executor <different-harness>` handoff to Claude, Codex,
  Cursor, opencode, Pi, or Hermes; Legion preserves the parent trace, creates a fresh
  worktree, and enforces `LEGION_MAX_DEPTH` (default `2`). Implicit routes,
  same-harness nesting, direct adapter calls, and depth-limit bypasses fail closed.
  Pi and Hermes cross the filesystem boundary through an authenticated,
  single-use parent broker. It accepts only one typed explicit-run request,
  rejects opaque/internal/apply/keep controls, and runs the target in a
  standalone disposable repository under its own equivalent OS boundary. The
  source cannot write the target repository, and the target cannot write source
  artifacts or parent Git administration. Target output is streamed under a
  fixed cap, and only fully validated, size-bounded `legion.span.v1` records
  from a no-symlink source chain can reach the parent telemetry store.

> **The sandbox is the security boundary — not the task scanner.** `scan_task_text`
> is a best-effort tripwire and is trivially bypassable (encodings, indirection);
> never treat a passed scan as proof a task is safe. Codex uses its native
> `--sandbox`; Pi and Hermes add an OS filesystem boundary around the worktree.
> Other adapters use their documented provider sandbox plus the isolated git
> worktree. A `workspace-write` run can still
> modify any file *inside that worktree* (including repo dotfiles like `.zshenv`
> if they exist there). For anything touching secrets or untrusted input, use a
> `read-only` sandbox or refuse — do not rely on the scanner.

## Cost note

The configured Codex role may use subscription auth, which reports token counts but **no per-token price** — so its cost can default to `$0` (token-count parity, not dollar). Set real prices in `config/costs.json` (or `LEGION_COSTS_FILE`) if you have API billing.

## Routing proxy (optional, opt-in)

The bundled `:8082` proxy meters Claude/MiniMax traffic translation-free (base-URL+auth swap). It is **opt-in** — only traffic you explicitly point at it via `ANTHROPIC_BASE_URL` is routed; your main session is never forced through it. See `references/routing-policy.md`.

Do **not** set a global `ANTHROPIC_BASE_URL=http://127.0.0.1:8082` unless
`legion-doctor --only router` is clean in the same environment. A forced global
proxy turns router downtime, launchd drift, or stream timeout bugs into repeated
Claude API failures. Prefer per-command opt-in for metering experiments.

Keep `ANTHROPIC_BASE_URL` client-facing. Override the router's actual upstreams
only with `LEGION_ANTHROPIC_UPSTREAM_URL` or
`LEGION_MINIMAX_UPSTREAM_URL`; self-targeting loopback overrides are rejected.
