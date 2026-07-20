# legion-orchestrate

Legion's dynamic **multi-model** orchestrator — the ultracode loop, but Claude conducts while the configured Codex workhorse does the bulk of coding in parallel and independent Fable review verifies.

> Decompose → fan out (configured Codex, parallel) → cross-model verify (independent Fable) → synthesize → gate.

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

## `legion-fanout`

Run many scoped slices in **parallel** across executors and collect verified diffs + cost:

```bash
printf '%s\n' \
  '{"archetype":"implement-feature","task":"build the X module per <spec>"}' \
  '{"archetype":"write-tests","task":"unit tests for X"}' \
  '{"archetype":"deep-reasoning","task":"decide the data model"}' \
  | legion-fanout --slices - --repo . --max-concurrency 4
```

- Codex slices run in parallel git worktrees via `legion-delegate`; `self`/`deep-reasoning` slices return `status:"inline"` for Claude to do.
- Output: per-slice `{status, model, diff_path, cost_usd}` + totals + `by_model` + `total_cost_usd`.
- Bounded by `--max-concurrency` (or `LEGION_MAX_CONCURRENCY`, default 4). Portable to bash 3.2.

## The playbook + ultracode mode

`SKILL.md` is the orchestration playbook (decompose → fan out → cross-model verify → synthesize → gate). `LEGION_ULTRACODE=1` goes maximally exhaustive: wide fan-out, multi-vote verify (independent Fable reviewer **and** the primary engineer must approve), loop-until-dry — all metered, kept ≥50% codex via `legion-share`.

## Depends on

`legion-router` (`legion-delegate`, `legion-route`, `routing.toml`) and `legion-observability` (`legion-trace`, `legion-share`). Requires `codex` (authenticated), `jq`, `git`.
