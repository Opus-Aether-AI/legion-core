# PR 54 Best-Model Live Checks

Generated: 2026-07-02. Branch: `feat/legion-live-bench-v1`.

## Heldout OSS Hard, Composer 2.5 + GPT-5.5

Command shape:

```bash
CODEX_MODEL=gpt-5.5 CURSOR_MODEL=composer-2.5 LEGION_CURSOR_MODEL=composer-2.5 \
LEGION_BENCH_DIR=/tmp/legion-pr54-hard-live-v2-20260702T144703Z/bench \
LEGION_TELEMETRY_DIR=/tmp/legion-pr54-hard-live-v2-20260702T144703Z/spans \
legion-bench corpus --corpus heldout-oss-hard --repo . \
  --mode direct-codex --mode legion-delegate --mode cursor-agent --mode legion-cursor \
  --baseline direct-codex --repeat 1 --record-failures --require-reliable \
  --report-md /tmp/legion-pr54-hard-live-v2-20260702T144703Z/heldout-oss-hard-live.md --json
```

Result artifact:
`/tmp/legion-pr54-hard-live-v2-20260702T144703Z/bench/corpus/20260702T144703Z-heldout-oss-hard-56d2cbf6/run.json`

| Mode | Model | Pass | Provider-blocked | Case-runs | Cost | Tokens |
|---|---|---:|---:|---:|---:|---:|
| `cursor-agent` | `composer-2.5` | 19 | 0 | 19 | $0.000000 | 1,518,717 |
| `legion-cursor` | `composer-2.5` | 19 | 0 | 19 | $0.000000 | 1,524,596 |
| `direct-codex` | `gpt-5.5` | 0 | 19 | 19 | $0.000000 | 0 |
| `legion-delegate` | `gpt-5.5` | 0 | 19 | 19 | $0.000000 | 0 |

The Cursor paths are real quality results: both direct Cursor Agent and the
Legion Cursor wrapper passed the full 19-case hard corpus on `composer-2.5`.

The Codex paths are not quality results for the full corpus. The local Codex CLI
hit a provider usage limit during the first direct Codex case. The table above
recategorizes those zero-token failures from the captured stdout; the harness was
then patched so future corpus runs classify provider quota/rate-limit cases as
`status: blocked` before validators run.

## GPT-5.5 Post-Reset Smoke

After the reported quota reset, a one-case Codex corpus (`py-bracket-stack`) was
run to verify the model pin itself:

```bash
CODEX_MODEL=gpt-5.5 legion-bench corpus --corpus /tmp/legion-pr54-codex-smoke-20260702T151653Z/codex-one.json \
  --repo . --mode direct-codex --mode legion-delegate --baseline direct-codex \
  --repeat 1 --reliability-min-cases 1 --record-failures \
  --report-md /tmp/legion-pr54-codex-smoke-20260702T151653Z/codex-one.md --json
```

| Mode | Model | Pass | Blocked | Cost | Tokens |
|---|---|---:|---:|---:|---:|
| `direct-codex` | `gpt-5.5` | 1/1 | 0 | $0.119009 | 80,034 |
| `legion-delegate` | `gpt-5.5` | 1/1 | 0 | $0.172747 | 81,246 |

## Direct Claude Opus

After Claude Code access recovered, `direct-claude` was run on the full 19-case
hard corpus with `CLAUDE_MODEL=opus`:

```bash
CLAUDE_MODEL=opus \
LEGION_BENCH_DIR=/tmp/legion-pr54-claude-opus-hard-20260702T152028Z/bench \
LEGION_TELEMETRY_DIR=/tmp/legion-pr54-claude-opus-hard-20260702T152028Z/spans \
legion-bench corpus --corpus heldout-oss-hard --repo . \
  --mode direct-claude --baseline direct-claude --repeat 1 --record-failures \
  --report-md /tmp/legion-pr54-claude-opus-hard-20260702T152028Z/direct-claude-opus-hard.md --json
```

| Mode | Model | Pass | Blocked | Case-runs | Cost | Tokens | Mean ms | P95 ms |
|---|---|---:|---:|---:|---:|---:|---:|---:|
| `direct-claude` | `opus` | 19 | 0 | 19 | $7.840890 | 3,624,469 | 29,289 | 43,306 |

Result artifact:
`/tmp/legion-pr54-claude-opus-hard-20260702T152028Z/bench/corpus/20260702T152028Z-heldout-oss-hard-bffb15ab/run.json`
