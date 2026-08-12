# legion-orchestrate

Legion's dynamic **multi-model** orchestrator: the active primary decomposes
work, configured executor roles implement parallel slices, and an independent
review role verifies the result.

> Decompose → fan out → cross-model verify → synthesize → gate.

## `legion-run`

Run any heavy task through the fixed Legion lifecycle. Use direct mode for
one-off feature/app/refactor work, or use an installed domain plugin when you
want the same workflow every time: doctor, self-learn hints, plan,
route, fan-out/apply, deterministic validation, final review, evaluation, observability HTML,
share accounting, self-learn, and heal planning.

Direct mode:

```bash
legion-run \
  --repo . \
  --task "Build the requested app change" \
  --name app-change \
  --plan-file ./PLAN.md \
  --plan-file ./ARCHITECTURE.md \
  --slices-file ./slices.jsonl \
  --validate-command "npm test && npm run build && printf '{\"ok\":true}\\n'" \
  --evaluate-command "./scripts/eval-app-change" \
  --json
```

Repeat `--plan-file` to combine product, architecture, migration, or eval notes.
Each relative file path is resolved from `--repo` and merged into `plan.json`.
Provide the matching explicit queue with `--slices-file`, or use a plan command
that writes `$LEGION_RUN_SLICES_FILE`.

Domain plugin mode:

```bash
legion-run \
  --plugin-manifest /path/to/my-product-plugin/legion-plugin.toml \
  --repo . \
  --task "Build the requested app change" \
  --json
```

Required plugin manifest:

```toml
[plugin]
name = "my-product-plugin"
kind = "domain-plugin"

[pipeline]
profile = "legion.heavy_task.v1"
entrypoint = "legion-run"

[commands]
plan = "my-product-plan"
validate = "my-product-validate"
evaluate = "my-product-eval"
```

Installed plugins should pass their own manifest path. Repo-local manifests under
`.legion/plugins/<name>/legion-plugin.toml` are optional overrides, not required
per-repo setup.

`legion.full_app.v1` remains supported for existing app-builder plugins, but
new plugins should use `legion.heavy_task.v1`.

The `plan` command must write `plan.json` and `slices.jsonl`. The plan owns the
work queue; Core executes it and retains the evidence. The old generic TDD
slice generator is available only through the explicit
`--allow-generated-slices` compatibility flag. External stages are bounded by
`--stage-timeout-seconds` (default 1800); timeout or cancellation writes a
terminal receipt and stops the stage's owned process group.
`stage-status.json` retains start/completion timestamps and explicit terminal
states (`passed`, `failed`, `timed_out`, or `not_run`) for every lifecycle stage.

Validator and evaluator commands run without inherited executor-role variables,
so a parent Legion session cannot silently change their behavior. Before final
review, `legion-run` writes the current worktree through a temporary Git index
to an immutable snapshot commit. Review artifacts record the exact base, head,
and tree SHAs rather than relying on a moving branch name. The source worktree
must be clean when `legion-run` starts; this prevents unrelated local or secret
files from being included in the external review snapshot.

### Learning-context boundary

Before planning, `legion-run` compiles one trusted, bounded
`learning-context.json` and its matching `learning-usage.json`. It exposes the
immutable path and content revision through `LEGION_LEARNING_CONTEXT_PATH` and
`LEGION_LEARNING_CONTEXT_REVISION`; planners and deterministic validators can
therefore consume the same bytes. Plan guidance is included in `LEGION_TASK`;
in required mode a planner or validator must return
`learning_context_ack: {boundary, revision}` before delivery is attested. The
plan contract, delegated slice tasks,
review input, and `learning-receipts.json` retain only dispositions and
maintainer-authored guidance. Raw session transcripts, evidence payloads, and
evidence excerpts never cross this boundary.

Use `--learning-context-mode off|observe|advisory|required` (or
`LEGION_LEARNING_CONTEXT_MODE`) to choose compatibility behavior. The default
is `advisory`: trusted selected guidance is delivered but ordinary delivery
remains non-blocking. `observe` records the typed context without inserting its
guidance; `off` produces an empty typed contract for older callers; `required`
marks every selected trusted hint as required and fails closed when compilation,
direct injection, boundary/revision acknowledgement, or deterministic
verification cannot be completed. Aggregate delivery receipts have a canonical
receipt ID and are SHA-256-bound by the artifact manifest.

## `legion-fanout`

Run many scoped slices in **parallel** across executors and collect verified diffs + cost:

```bash
printf '%s\n' \
  '{"archetype":"implement-feature","task":"build the X module per <spec>"}' \
  '{"archetype":"write-tests","task":"unit tests for X"}' \
  '{"archetype":"deep-reasoning","task":"decide the data model"}' \
  | legion-fanout --slices - --repo . --max-concurrency 4
```

- Delegated slices run in parallel git worktrees via `legion-delegate`;
  `self` slices return `status:"inline"` for the active primary.
- Output includes per-slice `{status, model, diff_path, cost_usd}`, aggregate
  totals, and `task_ledger_path`.
- `task_ledger_path` points to a durable `legion.task-ledger.v1` record with
  queued, started, terminal, dependency, run-ID, immutable base-SHA, and
  per-slice apply evidence. Interrupted runs therefore distinguish work that
  never started from work that failed after launch.
- Bounded by `--max-concurrency` (or `LEGION_MAX_CONCURRENCY`, default 4). Portable to bash 3.2.

## The playbook + ultracode mode

`SKILL.md` is the orchestration playbook (decompose → fan out → cross-model verify → synthesize → gate). `LEGION_ULTRACODE=1` goes maximally exhaustive: wide fan-out, multi-vote verify (the independent reviewer **and** the primary engineer must approve), and loop-until-dry. `legion-share` reports against a configurable advisory work-split target whose default is `0.5`.

## Depends on

`legion-router` (`legion-delegate`, `legion-route`, `routing.toml`) and `legion-observability` (`legion-trace`, `legion-share`). Requires `codex` (authenticated), `jq`, `git`.
