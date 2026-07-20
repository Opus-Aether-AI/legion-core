# legion-run

First-class cross-harness skill for the `legion-run` heavy-task lifecycle.

`legion-run` itself is installed as a CLI binary by `@opus-aether-ai/legion-core`.
This directory exposes the same capability as an agent skill so Claude, Codex,
Cursor, and other skill-aware CLIs can invoke the run lifecycle by name.

Use it for substantial work that needs an auditable execution contract:

- doctor and prior self-learning hints
- planning from a plan file, plan command, or domain plugin
- route and fan-out/apply
- deterministic validation
- final review and optional evaluation
- HTML/JSON evidence
- share accounting
- validation-led self-learning
- heal planning

## The Simple Idea

`legion-run` turns a coding task into a repeatable operating loop:

1. check the environment;
2. load prior lessons;
3. plan the work;
4. route and fan out slices;
5. run deterministic validation;
6. review the result and run evals;
7. write HTML/JSON evidence;
8. turn reusable findings into future memory;
9. write a heal plan when something breaks.

That is why it is useful for businesses: different developers or agents can
start from the same task, but the run is judged through the same validation
contract and the same shared memory.

## Direct Mode

Use direct mode when you have a plan and validation command:

```bash
legion-run \
  --repo . \
  --task "Add organization invitations with tests and review" \
  --name org-invitations \
  --plan-file ./plans/org-invitations.md \
  --slices-file ./plans/org-invitations.slices.jsonl \
  --validate-command "npm test && npm run build && printf '{\"ok\":true}\\n'" \
  --evaluate-command "./scripts/eval-org-invitations" \
  --json
```

You can also pass multiple `--plan-file` values. Relative paths are resolved
from `--repo`.

## Domain Plugin Mode

Use plugin mode when a team has a reusable workflow:

```bash
legion-run \
  --plugin-manifest /path/to/support-app-builder/legion-plugin.toml \
  --repo . \
  --task "Build SLA escalation" \
  --json
```

The plugin supplies executable `plan`, `validate`, and `evaluate` hooks. Legion
Core supplies the lifecycle.

## Validation-Led Self-Learning

Validators can return structured lessons, not only pass/fail:

```json
{
  "ok": false,
  "learning_feedback": [
    {
      "id": "missing-contract-test",
      "source": "validation-feedback",
      "target_type": "skill",
      "target_name": "legion-run",
      "severity": "high",
      "summary": "Validation found a missing idempotency contract.",
      "evidence": {"gate": "integration"}
    }
  ]
}
```

`legion-run` writes those lessons to `learning-feedback.json`, appends them to
Legion self-learning outcomes, and runs `legion-self-learn run --apply-memory`.
It now also does this on failed runs when enough artifact evidence exists, such
as doctor failures, fanout failures, validation failures, eval failures, and
terminal failure summaries.

## Where To Look

The JSON output includes `run_dir`. Open these files:

- `legion-observability.html` for the human-readable run story;
- `artifact-manifest.json` for every expected artifact and whether it exists;
- `learning-feedback.json` for lessons harvested from validation and failures;
- `self-learn.json` and `self-learn-run.json` for memory application;
- `heal-plan.json` for the repair plan.
