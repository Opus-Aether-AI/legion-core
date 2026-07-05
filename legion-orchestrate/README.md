# legion-orchestrate

Legion's dynamic **multi-model** orchestrator — the ultracode loop, but Claude conducts while the configured Codex workhorse does the bulk of coding in parallel and the configured Codex reviewer verifies.

> Decompose → fan out (configured Codex, parallel) → cross-model verify (configured reviewer) → synthesize → gate.

## `legion-run`

Run a domain plugin through the fixed full-app Legion pipeline. Use this from
installed app-builder or domain plugins when you want the same workflow every
time: doctor, self-learn hints, plugin plan, route, fan-out/apply, final review,
plugin validation, plugin evaluation, observability HTML, share accounting,
self-learn, and heal planning.

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
profile = "legion.full_app.v1"
entrypoint = "legion-run"

[commands]
plan = "my-product-plan"
validate = "my-product-validate"
evaluate = "my-product-eval"
```

Installed plugins should pass their own manifest path. Repo-local manifests under
`.legion/plugins/<name>/legion-plugin.toml` are optional overrides, not required
per-repo setup.

The `plan` command must write `plan.json`. It may also write `slices.jsonl` for
full control. If it only writes a brief plan with `mode =
"legion-generate-slices"`, `legion-run` generates a compact default TDD slice
set from that brief and records it as `slices.jsonl` in the run directory.

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

`SKILL.md` is the orchestration playbook (decompose → fan out → cross-model verify → synthesize → gate). `LEGION_ULTRACODE=1` goes maximally exhaustive: wide fan-out, multi-vote verify (configured Codex reviewer **and** Claude must approve), loop-until-dry — all metered, kept ≥50% codex via `legion-share`.

## Depends on

`legion-router` (`legion-delegate`, `legion-route`, `routing.toml`) and `legion-observability` (`legion-trace`, `legion-share`). Requires `codex` (authenticated), `jq`, `git`.
