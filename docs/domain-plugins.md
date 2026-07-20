# Domain Plugins

A domain plugin lets you sell Legion Core to a specific software business
without baking that business logic into the core engine.

Legion Core handles routing, fan-out, review, reports, memory, and repair.
Your plugin handles reusable domain language, plans with exact slices,
validation, and evals.

You do not need a domain plugin for every big task. Use `legion-run` direct mode
when a one-off plan/validate/evaluate setup is enough. Build a plugin when you
want the same domain workflow reused across many repos or customer demos.

## Mental Model

```text
Skill file      -> optional agent instructions for Codex/Claude/Cursor
Manifest        -> tells legion-run which executable hooks to call
Plan hook       -> writes plan.json and slices.jsonl
Validate hook   -> runs app gates after code is applied
Evaluate hook   -> scores whether the domain goal was met
legion-run      -> enforces the heavy-task lifecycle around those hooks
```

The hooks are **commands/executables**, not skills. A hook can be a shell script,
Node script, Python script, or wrapper around private Legion Code logic.

## Layout

```text
support-app-builder/
  legion-plugin.toml
  bin/
    support-plan
    support-validate
    support-eval
  SKILL.md        # optional agent instructions
```

Installed plugins should pass their bundled manifest path to `legion-run`.
Repo-local manifests under `.legion/plugins/<name>/legion-plugin.toml` are
useful when a repo wants to pin or override plugin behavior.

## Manifest

```toml
[plugin]
name = "support-app-builder"
kind = "domain-plugin"

[pipeline]
profile = "legion.heavy_task.v1"
entrypoint = "legion-run"

[commands]
plan = "support-plan"
validate = "support-validate"
evaluate = "support-eval"
```

`legion-run` rejects the manifest unless:

- `[plugin].kind` starts with `domain-`
- `[pipeline].entrypoint` is `legion-run`
- `[pipeline].profile` is `legion.heavy_task.v1` or `legion.full_app.v1`
- `plan`, `validate`, and `evaluate` are present

Use `legion.heavy_task.v1` for new plugins. `legion.full_app.v1` remains
supported for existing app-builder manifests.

`legion-doctor --only domain-plugin` checks repo-local manifests for the same
contract. `legion-doctor --strict-demo` includes that check.

## Optional Skill File

You do not need a skill file to use the plugin directly. This works:

```bash
legion-run --plugin-manifest ./legion-plugin.toml --repo . --task "Build SLA escalation" --json
```

Add `SKILL.md` only when you want the agent runtime to discover the plugin from
natural language.

```md
---
name: support-app-builder
description: Use when building or changing a customer-support SaaS app.
---

For support-app changes:

1. Translate the user request into the domain goal.
2. Run `legion-run --plugin-manifest <plugin-dir>/legion-plugin.toml --repo . --task "<request>" --json`.
3. Open the returned `run_dir/legion-observability.html`.
```

The skill can also name supporting skills. For example, a SaaS app-builder
plugin may ask the agent to use:

- `software-architect` for service boundaries, APIs, validation, and risk
- `ai-architect` for model output contracts, uncertainty, cost, safety, evals
- `domain-modeling` for entities and invariants
- `vercel:nextjs` for App Router structure
- `vercel:ai-sdk` for AI SDK integration
- `zod` for schemas
- `javascript-testing-patterns` and `e2e-testing-patterns` for tests
- `owasp-security` and `secret-scanning` for trust boundaries

## Plan Hook

The plan hook always writes `plan.json` using `$LEGION_RUN_PLAN_FILE`.

It has one production mode and one migration escape hatch:

| Mode | Use when |
|---|---|
| Explicit slices | The plugin writes the executable work queue to `$LEGION_RUN_SLICES_FILE`. |
| Legacy generated slices | An operator may pass `--allow-generated-slices` while migrating an old brief-only plan. |

### Legacy brief-only plan

This is supported only while migrating an existing app-builder plugin.

Example `bin/support-plan`:

```bash
#!/usr/bin/env bash
set -euo pipefail

cat > "$LEGION_RUN_PLAN_FILE" <<JSON
{
  "schema": "legion.plugin.plan.v1",
  "plugin": "$LEGION_PLUGIN_NAME",
  "mode": "legion-generate-slices",
  "task": "$LEGION_TASK",
  "planning_instruction": "Read the product plan and build this TDD style: write failing tests, implement the minimum code to pass, then refactor after green.",
  "context_files": ["PLAN.md"],
  "required_skills": ["software-architect", "ai-architect", "javascript-testing-patterns"],
  "quality_gates": ["lint", "typecheck", "test", "build"],
  "eval_goal": "The requested workflow works end to end."
}
JSON
```

If the hook does not create `slices.jsonl`, `legion-run` fails the plan stage.
An operator may pass `--allow-generated-slices` to request the old generic TDD
queue explicitly during migration; product workflows must not rely on it.

### Exact slices

Use this when the plugin needs full control over the Legion fan-out queue:

```bash
#!/usr/bin/env bash
set -euo pipefail

cat > "$LEGION_RUN_PLAN_FILE" <<JSON
{
  "schema": "legion.plugin.plan.v1",
  "plugin": "$LEGION_PLUGIN_NAME",
  "task": "$LEGION_TASK"
}
JSON

cat > "$LEGION_RUN_SLICES_FILE" <<JSONL
{"archetype":"implement-feature","task":"Build backend/API for: $LEGION_TASK"}
{"archetype":"implement-feature","task":"Build UI workflow for: $LEGION_TASK"}
{"archetype":"write-tests","task":"Add unit and integration tests for: $LEGION_TASK"}
JSONL
```

## Validate Hook

The validate hook proves the repo still works technically.

Example `bin/support-validate`:

```bash
#!/usr/bin/env bash
set -euo pipefail

npm test
npm run build
printf '{"ok":true,"gates":["npm test","npm run build"]}\n'
```

Use this for deterministic gates: tests, typecheck, lint, build, Playwright,
schema checks, security checks, or app-specific validators.

## Evaluate Hook

The evaluate hook scores the domain outcome.

Example `bin/support-eval`:

```bash
#!/usr/bin/env bash
set -euo pipefail

printf '{"ok":true,"score":1,"total":1,"checks":["support workflow implemented"]}\n'
```

This is where you encode the business rubric. For a dispatch app, the eval might
check that a technician has the right skill, parts are available, SLA is not
missed, and the customer reply includes an ETA.

## Run It

```bash
chmod +x support-app-builder/bin/*
export PATH="$PWD/support-app-builder/bin:$PATH"

legion-run \
  --plugin-manifest "$PWD/support-app-builder/legion-plugin.toml" \
  --repo /path/to/app \
  --task "Add SLA-based ticket escalation" \
  --json
```

The output includes `run_dir`. Inspect:

```text
<run_dir>/legion-observability.html
```

## Required Pipeline Artifacts

`legion-run` only succeeds when the run directory contains the full evidence
contract:

```text
doctor.json
self-learn-hints.json
plan.json
slices.jsonl
routes.json
fanout.json
review.json
validation.json
eval.json
legion-report.json
legion-report.html
legion-observability.html
share.json
self-learn.json
heal-plan.json
artifact-manifest.json
```

That is why a domain plugin can stay small: it supplies the three domain hooks,
while Legion Core guarantees the workflow and proof trail.
