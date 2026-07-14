---
name: legion-run
kind: procedure
# disable-model-invocation intentionally false: this skill invokes the user's configured Legion executor stack.
description: Use to execute a substantial coding task through `legion-run`'s enforced heavy-task lifecycle. Triggers on "legion run", "run this with Legion", "use legion-run", "full lifecycle", "plan and execute", "plan/validate commands", "domain plugin", "validated self-learning", or requests that need doctor, prior hints, planning, route/fan-out/apply, review, validation, evaluation, HTML evidence, share accounting, learning, and heal planning.
---

# Legion Run - validated heavy-task execution

Use this skill when the user wants Legion to **run** a coding task end to end,
not only decompose it. `legion-run` is the fixed execution contract for serious
work: doctor, self-learn hints, plan, route, fan-out/apply, final review,
validation, evaluation, observability HTML, share accounting, self-learn, and
heal planning.

Prefer this over manually composing `legion-fanout`, `legion-delegate`,
`legion-report`, and `legion-self-learn` when the task needs proof and a durable
run directory.

## Mode selection

Use **direct mode** for one-off tasks where the current repo can provide the
plan and validation command:

```bash
legion-run \
  --repo . \
  --task "Build the requested change" \
  --name requested-change \
  --plan-file /tmp/legion-run-plan.md \
  --validate-command "npm test && npm run build && printf '{\"ok\":true}\n'" \
  --json
```

Use **domain plugin mode** when a product, repo, or business workflow has a
reusable manifest with plan/validate/evaluate commands:

```bash
legion-run \
  --plugin-manifest /path/to/domain-plugin/legion-plugin.toml \
  --repo . \
  --task "Build the requested change" \
  --json
```

## Direct mode workflow

1. Identify the target repo. Default to the current working directory.
2. Inspect the repo's normal validation commands before choosing a gate.
3. Create or reuse a concise plan file. Markdown is accepted; `legion-run`
   converts it into `plan.json` and generates default TDD slices when needed.
4. Choose a validation command that returns nonzero on failure and, when useful,
   prints JSON with `learning_feedback` or `learning_outcomes`.
5. Run `legion-run --repo <repo> --task <task> --plan-file <file>
   --validate-command <command> --json`.
6. Open or report the returned `run_dir` and the HTML artifacts there.

For validation-led self-learning, validators may emit:

```json
{
  "ok": true,
  "learning_feedback": [
    {
      "id": "domain-invariant",
      "source": "validation-feedback",
      "target_type": "heavy-task",
      "target_name": "requested-change",
      "severity": "medium",
      "summary": "Reusable lesson discovered by validation.",
      "evidence": {"validator": "repo gate", "passed": true}
    }
  ]
}
```

`legion-run` records that feedback into `learning-feedback.json`, appends it to
self-learning outcomes, runs `legion-self-learn run --apply-memory`, and
includes the result in the HTML report. Failed runs also attempt this finalizer
when artifacts such as `doctor.json`, `fanout.json`, `validation.json`,
`eval.json`, or `failure.json` contain useful evidence.

## Domain plugin mode workflow

Use this when the repo or business has reusable hooks:

```toml
[plugin]
name = "example-domain"
kind = "domain-plugin"

[pipeline]
profile = "legion.heavy_task.v1"
entrypoint = "legion-run"

[commands]
plan = "example-plan"
validate = "example-validate"
evaluate = "example-evaluate"
```

The plugin's commands are executables, not skills. They may be shell, Python,
Node, or private company CLIs. The plan command writes `plan.json` and may also
write `slices.jsonl` for exact control.

## Completion criteria

A successful `legion-run` answer should give the user:

- the run status and failed stage, if any;
- the `run_dir`;
- links or paths for `legion-observability.html`, `legion-report.html`, and
  `artifact-manifest.json`;
- the validation/evaluation result;
- any `learning-feedback.json` outcomes; and
- the heal plan if validation failed.

Do not claim success from model output alone. Treat validation, review, and the
run artifacts as the source of truth.
