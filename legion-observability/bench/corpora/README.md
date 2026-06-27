# Legion Bench Corpora

`legion-bench corpus` is the proper-number path. It runs the same cases across
multiple harness modes and reports pass rate, lift, duration, cost/tokens from
Legion spans, and sample-size reliability.

The packaged `local-smoke.json` corpus is only a runner smoke test. It is tiny
and intentionally marked unreliable for performance claims.

## Two corpus layers

The packaged live corpora are deliberately split into two layers, because they
measure different things:

- **`heldout-oss-36.json` — correctness-parity floor.** 36 Python micro-coding
  tasks (single 5-line functions). Every frontier model saturates this at ~100%,
  so it does **not** discriminate between harnesses; it only proves a harness does
  not *regress* raw model correctness, and it is the cheapest live smoke test.
- **`heldout-oss-hard.json` — discriminating tier.** 19 harder, held-out
  pure-Python tasks: multi-file (e.g. `account.py` + `bank.py`), longer-horizon
  (mini-parsers, state machines, topological sort), constrained bug-fixes, and
  rich multi-assertion edge cases. These are authored so a sloppy single-shot
  attempt fails at least one assertion, so pass rates land below 100% and
  harness differences (and the cost to achieve them) are visible. Validators are
  the oracle; `answer_files` pass and stubs fail (proven by the scripted-oracle /
  scripted-baseline control).

> **Cursor modes need a short workspace path.** `cursor-agent --trust` fails on
> very long / deeply-nested workspace paths (`Failed to trust workspace … check
> permissions`), which silently zeroes the `cursor-agent` and `legion-cursor`
> modes. Run the live bench with a short `LEGION_BENCH_DIR` (e.g. under `/tmp`);
> the CI workflow already uses the short `$RUNNER_TEMP`.

The packaged `heldout-oss-36.json` corpus is the first reliable held-out lane.
It contains 36 Python micro-coding tasks and defaults to no-spend deterministic
control modes:

```bash
legion-bench corpus \
  --corpus heldout-oss-36 \
  --repo . \
  --dry-run \
  --require-reliable \
  --json

legion-bench corpus \
  --corpus heldout-oss-36 \
  --repo . \
  --require-reliable \
  --strict \
  --report-md /tmp/heldout-report.md \
  --json
```

The default comparison is `scripted-baseline` versus `scripted-oracle`, so it
proves corpus mechanics, validators, paired stats, failure clustering, and report
generation without model spend. It is not a model-quality claim.

For live runs, select live modes explicitly:

```bash
legion-bench corpus \
  --corpus heldout-oss-36 \
  --repo . \
  --mode direct-codex \
  --mode legion-delegate \
  --baseline direct-codex \
  --require-reliable \
  --report-md /tmp/direct-codex-vs-legion.md \
  --json
```

Optional live modes currently packaged:

- `direct-codex`
- `legion-delegate`
- `direct-claude`
- `cursor-agent`
- `legion-cursor`

Live modes require the corresponding CLI and auth on the machine running the
bench. The adapters restore the real user `HOME` for the live CLI process so
Codex, Claude, and Cursor can read their normal auth state while the editable
task workspace remains isolated. GitHub Actions also has a manual
`legion-live-bench` workflow with an explicit `run_live=true` guard before any
live modes run.

## Live Corpus Template

Use 30+ held-out cases for a reliable comparison:

```json
{
  "schema": "legion.bench.corpus.v1",
  "corpus": "my-live-agent-corpus",
  "baseline": "direct-codex",
  "reliability_min_cases": 30,
  "modes": [
    {
      "id": "direct-codex",
      "command": [
        "bash",
        "-lc",
        "codex exec --json -m ${CODEX_MODEL:-gpt-5.4} -s workspace-write -C {workspace} --skip-git-repo-check - < {task_file}"
      ],
      "timeout": 900
    },
    {
      "id": "legion-delegate",
      "setup": [
        [
          "bash",
          "-lc",
          "git init -q && git add . && git -c user.email=bench@example.com -c user.name=bench commit -qm init"
        ]
      ],
      "command": [
        "bash",
        "-lc",
        "{repo}/legion-router/bin/legion-delegate run --archetype implement-feature --repo {workspace} < {task_file}"
      ],
      "timeout": 900
    }
  ],
  "cases": [
    {
      "id": "example",
      "dimension": "implementation",
      "summary": "Implement a function and pass its validator.",
      "task": "Edit app.py so `add(2, 3)` returns 5.",
      "files": {
        "app.py": "def add(a, b):\n    return 0\n",
        "test_app.py": "from app import add\nassert add(2, 3) == 5\n"
      },
      "commands": {
        "direct-codex": [
          "bash",
          "-lc",
          "codex exec --json -m ${CODEX_MODEL:-gpt-5.4} -s workspace-write -C {workspace} --skip-git-repo-check - < {task_file} && python3 test_app.py"
        ],
        "legion-delegate": [
          "bash",
          "-lc",
          "{repo}/legion-router/bin/legion-delegate run --archetype implement-feature --repo {workspace} --apply < {task_file} && python3 test_app.py"
        ]
      },
      "required": true
    }
  ]
}
```

Run it:

```bash
legion-bench corpus \
  --corpus ./my-live-agent-corpus.json \
  --mode direct-codex \
  --mode legion-delegate \
  --baseline direct-codex \
  --require-reliable \
  --json
```

Do not publish relative lift from a small corpus. Use percentage-point lift until
`reliable: true`.
