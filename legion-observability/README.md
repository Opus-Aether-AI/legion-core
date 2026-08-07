# legion-observability

See everything Legion's multi-model runs do — per-executor **cost, success rate, and latency** — verify the install is wired correctly, and turn failures into measured harness improvement experiments.

> One orchestrator, a legion of models — and one telemetry stream for all of them.

## Tools

| Bin | Script | What it does |
|---|---|---|
| `legion-report` | `scripts/legion-report.sh` (+ `legion-aggregate.py`, `legion-render.py`) | Cost / success-rate / p50-p95 latency, grouped by executor/model/status, as a TUI table or `--html`. |
| `legion-bench` | `scripts/legion-bench.py` | Harness Bench-style scorecards for Legion harness changes: deterministic `core`/`stable` suites, repeated-run flake detection, A/B `corpus` runs across harness modes, eval/route/doctor/fixture task cases, compare/gate commands, `learning-lift`, spans, and optional self-learning outcomes. |
| `legion-trace` | `scripts/legion-telemetry.sh` | `emit` a validated span; `validate` a span file/stream. |
| `legion-otel-export` | `scripts/legion-otel-export.py` | Map `legion.span.v1` → OTLP/HTTP; POST to `$OTEL_EXPORTER_OTLP_ENDPOINT` (no-op until set; `--dry-run` to preview). |
| `legion-doctor` | `scripts/legion-doctor.sh` | CI-usable verifier; exits nonzero on any hard-check failure. |
| `legion-catalog` | `scripts/legion-catalog.py` | Read-only inventory of plugins, skills, agents, commands, hooks, and MCPs. |
| `legion-learn` | `scripts/legion_learning.py` | Stream and redact cross-harness sessions into versioned sessions, episodes, decisions, outcome links, five behavior axes, 14 code-quality dimensions, and cross-project learning laws. |
| `legion-self-learn` | `scripts/legion-self-learn.py` | Daily self-learning loop: spans + review findings + trigger evals + benchmark misses + session feedback + manual bug records -> entity-scoped memory/proposals. `--apply-source` is a compatibility-only dry-run response. |
| `legion-improve` | `scripts/legion-improve.py` | Consume a maintainer-eligible typed proposal in `off` (default), `dry-run`, or `draft` mode. It freezes a base SHA, uses isolated worktrees, repeats paired gates, requires a receipt, and creates only idempotent draft PRs. |
| `legion-context-profile` | `scripts/legion-context-profile.py` | Reversibly shape active Codex/.agents skills and Claude plugins from external context profiles and skill groups when context budget gets noisy. |
| `legion-session-learn` | `scripts/legion-session-learn.py` | Mine bounded, provenance-aware Claude/Codex/Cursor sessions and project memories for recurring gotchas and explicit corrections; output and recorded outcomes use hashes/counts instead of transcript text by default. |

## Quick start

```bash
legion-doctor                       # is the install wired correctly?
legion-report                       # per-executor cost / success / latency
legion-bench run --suite core --repo . --strict
legion-bench stable --suite stable --repo . --repeat 3 --strict
legion-bench corpus --corpus local-smoke --repo . --json
legion-bench corpus --corpus heldout-oss-36 --repo . --dry-run --require-reliable --json
legion-bench corpus --corpus heldout-oss-36 --repo . --require-reliable --report-md /tmp/heldout.md --json
legion-bench compare --baseline runs/base/run.json --candidate runs/new/run.json
legion-bench gate --baseline runs/base/run.json --candidate runs/new/run.json
legion-report --by model --html > report.html
legion-state --repo . --field telemetry_dir
cat "$(legion-state --repo . --field telemetry_dir)"/*.jsonl | legion-otel-export --dry-run | jq .
legion-learn analyze --repo . --repo-only --json
legion-learn report --repo .
legion-learn laws --repo .
legion-session-learn --repo . --record     # scoped, privacy-safe session corrections
legion-self-learn run --apply-memory       # synthesize safe memory/proposals
legion-improve run --repo . --proposal proposal.json --state-dir .legion/improve --mode dry-run --json
legion-improve queue --repo . --base-ref main --mode dry-run --max 1 --json
legion-self-learn hints                    # active learned guardrails
legion-self-learn compile-context --repo . --entity skill:release --stage plan --json
legion-self-learn reconcile --repo . --legacy-state legacy-state.json --evidence evidence.jsonl --json
legion-context-profile list                # discover external profiles
legion-context-profile groups              # inspect reusable skill/plugin groups
legion-context-profile suggest --query "frontend monorepo tests"
legion-context-profile coverage \
  --skills-root ~/.agents/sources/legion \
  --skills-root ~/.agents/sources/legion/vendored \
  --marketplace ~/.agents/sources/legion/.claude-plugin/marketplace.json
legion-context-profile apply --dry-run     # preview profile/group context trim
legion-session-learn --repo . --query moneyball --record
legion-session-learn --repo . --harness codex --role user --query "wrong source" --json
legion-session-learn --repo . --show-evidence --query "review was interrupted"

# Emit a span from any runner/executor:
legion-trace emit --executor codex --model "$(legion-route --model-ref codex_workhorse)" --status ok \
  --cost 0.05 --duration-ms 1800 --tokens '{"input_tokens":12000}'
```

## The span contract

`schema/legion.span.v1.schema.json` — required `schema, ts, run_id, executor, model, status`; plus `cost_usd`, `duration_ms`, `tokens`, `trace_id`/`parent_id` (trace trees), `target_type`/`target_name` (self-learning attribution), `artifacts`. `legion-delegate` already emits it.

## Self-learning loop

The loop follows the
[svineet/harness-bench](https://github.com/svineet/harness-bench) /
[autoresearch](https://github.com/karpathy/autoresearch) shape:
observe -> analyze -> propose -> baseline -> isolate -> mutate -> score -> keep/discard.

- **Observe:** normalize cross-harness sessions with `legion-learn`, then read durable spans, review verdict artifacts, trigger eval misses, routing optimizer advice, benchmark misses, compatibility session feedback, and manual `legion-self-learn record` bug reports.
- **Analyze:** attach every outcome to a catalog entity (`plugin`, `skill`, `command`, `agent`, `hook`, or `mcp`) so slash commands and sub-agents improve too.
- **Score:** run plugin + entity `legion-eval` datasets and `legion-doctor`, then persist metrics in `experiments.tsv`.
- **Propose:** self-learning writes evidence and typed proposals; it never applies a source candidate to the operator checkout.
- **Promote:** explicit `--apply-memory` syncs bounded entity/stage hints into the
  project `learning/hints.json`, which official runs compile at each decision
  boundary. Raw model review prose never becomes trusted guidance.
- **Improve:** `legion-improve` is off by default. In `draft` mode it freezes the remote/base identity, confines an eligible documentation proposal to an isolated worktree and allowlists, rejects flake/regression gates, records an independent receipt, then opens a draft PR only. It never merges or deploys.

The source-changing queue is deliberately narrower than memory. Only promoted
laws with confidence ≥0.9, at least five episodes across three projects, and a
safe Markdown target are eligible. The proposal supplies bounded text to one
native mutator; it cannot supply a shell or validator command. Independent
approval comes from `legion-delegate review` over immutable base/head commits.
Set `LEGION_IMPROVE_MODE=dry-run` or `draft` to let daily refresh process at most
`LEGION_IMPROVE_MAX` proposals (default 1); the default remains `off`.

When the optional daily `legion-refresh` cron is enabled, it first records
recent session feedback, then runs the self-learning synthesis:

```bash
legion-learn analyze --repo .
legion-session-learn --repo . --record
legion-self-learn run --apply-memory --quiet
# opt-in only: LEGION_IMPROVE_MODE=draft scripts/refresh.sh
```

Promoted laws require three independent episodes across two projects. Active
laws become proposals in `legion-self-learn`; laws unsupported by the current
report set are retired instead of silently remaining active.

The scan is bounded to the newest 100 eligible sources by default. It excludes
system/developer catalogs, tool results, collaboration subagents, and sources
marked as benchmark/eval fixtures. Equivalent records emitted twice by a
harness are deduplicated. `--repo`, `--harness`, `--role`, and `--source-kind`
provide tighter provenance scope; `--session-limit 0` explicitly restores an
unbounded scan.

Candidate and recorded evidence contains only counts, stable hashes, roles, and
source kinds. `--show-evidence` adds best-effort-redacted snippets and
home-relative paths to command output for an intentional local audit; inspect
that output before sharing it. Raw snippets are never copied into durable
self-learning outcomes. That keeps the daily mode conservative while still
turning corrections and review gotchas into memory/proposals. Set
`LEGION_EVIDENCE_LEARN=0` or `LEGION_SESSION_LEARN=0` to skip the corresponding
refresh scan.

## Layout

```
legion-observability/
├── bin/{legion-report,legion-doctor,legion-trace,...} # PATH shims
├── bench/core.json                                    # offline benchmark suite
├── schema/*.schema.json                              # telemetry + learning contracts
├── scripts/
│   ├── legion-telemetry.sh     # emit + validate spans
│   ├── legion-aggregate.py     # roll up spans -> per-group metrics
│   ├── legion-render.py         # aggregate JSON -> TUI / HTML
│   ├── legion-bench.py          # offline benchmark run/compare/gate
│   ├── legion-report.sh         # aggregate | render
│   ├── legion-otel-export.py    # spans -> OTLP/HTTP trace tree
│   ├── legion-self-learn.py     # daily self-learning memory/proposals
│   ├── legion-improve.py        # crash-safe review-only proposal engine
│   ├── legion_learning.py       # evidence-linked session learning v2
│   └── legion-doctor.sh         # install verifier
└── SKILL.md
```

## Tests

- `tests/telemetry.bats`, `tests/doctor.bats` (bash, run under the repo BATS suite).
- `tests/python/` — Python unit tests for aggregation, catalog, eval, context tuning, self-learning, and export; run `bash tests/python/run-tests.sh` (uvx pytest).

## Env

- `LEGION_TELEMETRY_DIR` — span dir (default:
  `~/.legion/projects/<repo-id>/spans`).
- `LEGION_BENCH_DIR` — benchmark artifact dir (default:
  `~/.legion/projects/<repo-id>/bench`).
- `legion-state --repo .` — print every resolved project path and override
  source.
- `OTEL_EXPORTER_OTLP_ENDPOINT` — enables real OTLP export; unset = no-op.
- `LEGION_SESSION_LEARN=0` — disable refresh-time session mining.
- `LEGION_EVIDENCE_LEARN=0` — disable refresh-time evidence-linked learning.
- `LEGION_IMPROVE_MODE=off|dry-run|draft` — bounded refresh-time typed
  improvement processing (default: `off`). `LEGION_IMPROVE_MAX` defaults to 1.
- `LEGION_IMPROVE_REVIEW_BIN` — independent review boundary (default:
  `legion-delegate`). `LEGION_IMPROVE_VALIDATOR_BIN` optionally adds one
  operator-configured paired validator; proposals cannot set either command.
- `LEGION_PROJECT_LEARNING_DIR`, `LEGION_GLOBAL_LEARNING_DIR` — override the
  project report and cross-project law roots.
- `LEGION_SESSION_LEARN_DAYS`, `LEGION_SESSION_LEARN_LIMIT`, and
  `LEGION_SESSION_LEARN_MAX_FILE_MB` — bound the repo-scoped refresh scan
  (defaults: 3 days, 100 sources, 8 MiB for non-JSONL files).
