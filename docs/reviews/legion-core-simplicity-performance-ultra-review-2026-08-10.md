# Legion Core simplicity and performance ultra review

## Review target

- Repository: `Opus-Aether-AI/legion-core`
- Reviewed ref: `origin/main`
- Immutable SHA: `471d498a1db92bada82cc688720d079045378bbd`
- Mode: report only
- Confidence threshold: 80/100
- Review date: 2026-08-10

The review found eight high-severity and four medium-severity actionable
finding groups, plus two lower-priority cleanup items. No product source was
changed. The local checkout already contained
unrelated user changes, so evidence was taken from the immutable `origin/main`
snapshot and read-only reproductions.

## Shards and lenses

Three parallel shards covered runtime/routing, learning/observability, and the
cross-repository catalog/install boundary. Each was reviewed through
correctness, architecture, performance, testing/regression, repository policy,
and the `simplicity-first` complexity lens. No repository-local domain reviewer
matched this review.

## Findings ledger

### High

| Confidence | Finding | Evidence | Simpler move |
|---:|---|---|---|
| 100 | Cancellation can leave executor/MCP process groups running. `run_process()` creates a new session but only performs group cleanup on timeout; SIGINT/SIGTERM raises past that cleanup. A reproduction observed `child_survived_cancel=yes`. | `legion-orchestrate/scripts/legion-run.py:755-779,3007-3015` | Put process-group termination in one helper and invoke it for timeout and every exceptional exit before re-raising. |
| 100 | Anthropic fallback requests bypass primary streaming/non-streaming metering, hiding requests, tokens, and spend when fallback cost matters most. | `legion-router/scripts/router.ts:659-668,885-924` | Forward both primary and fallback responses through one metered response path; record the failed primary attempt separately. |
| 100 | `meteredSSEStream()` drains upstream in `start()` and enqueues without downstream demand, allowing a slow client to accumulate an entire response in memory. | `legion-router/scripts/router.ts:332-350` | Read one upstream chunk from `pull()` and cancel the upstream reader on downstream cancellation. |
| 100 | Fixed `MAXC` batch barriers leave concurrency slots idle behind the slowest slice. With two slots and durations `[10,1,10,1]`, the current shape takes about 20 units instead of about 11. | `legion-orchestrate/scripts/legion-fanout.sh:691-700,752-758` | Use a completion-driven bounded scheduler and release DAG dependants as soon as their own prerequisites finish. |
| 100 | Default self-learning reparses and materializes all historical spans and manual outcomes on every run. At 200,000 synthetic spans it used 0.866 s and 145.9 MB; growth is linear and unbounded. | `legion-observability/scripts/legion-self-learn.py:256-317,1241-1263,2453-2472`; `scripts/refresh.sh:191-198` | Keep atomic per-file offsets, bounded overlap/dedupe, and incremental aggregates; reserve full replay for explicit rebuild/recovery. |
| 100 | Learning ingestion is neither shared, pruned, nor fully streaming. The compatibility scanner materializes every JSONL record (80,000 records / 86.08 MB allocated 100.1 MB); v2 and compatibility parse overlapping files independently; and `Path.rglob` traverses ignored trees. | `legion-observability/scripts/legion-session-learn.py:455-506,565-599,687-714,857-875`; `legion_learning.py:553-621,773-818,1131-1179`; `scripts/refresh.sh:161-189` | Build one pruned, streaming normalized-session iterator for both classifiers. Preserve both rule sets until the 11 compatibility categories reach v2 parity. |
| 100 | Each console SSE client rebuilds all historical telemetry every 1.5 seconds. A 200,000-span snapshot took 2.467 s and 310.9 MB, already exceeding the interval before multiplying by client count; its activity path also ignores the configured custom span directory. | `legion-observability/scripts/legion-console-index.py:145-196`; `legion-console-serve.py:98-105,148-160`; `legion-activity.py:509-520` | Maintain one process-wide indexed snapshot, propagate the configured span path everywhere, and broadcast the cached view to clients. |
| 100 | `legion-share --window` echoes a time window but aggregates all history, so stale evidence affects routing. The supplied old/new fixture reported 83.33% Codex instead of 0% for one day. | `legion-observability/scripts/legion-share.py:48-65,164-177`; `legion-run.py:2943` | Stream only records newer than the cutoff, or delete the option and callers if all-time behavior is intended. |

### Medium

| Confidence | Finding | Evidence | Simpler move |
|---:|---|---|---|
| 100 | Doctor performs two non-pruned tree walks and multiple processes per skill. The current checkout returned 36 skills, 24 from `.claude/worktrees`; strict Doctor took 2.58 s versus 0.79 s on a clean archive. | `legion-observability/scripts/legion-doctor.sh:97-104,131-140,173-194` | Actually prune VCS, dependency, Legion, and worktree directories; parse frontmatter and descriptions in one cached pass. |
| 100 | A slice can be routed three times; the first `routes.json` is not consumed by execution. One hundred CLI route starts took 8.25 s versus 0.000303 s for in-process resolution after one config load. | `legion-orchestrate/scripts/legion-run.py:2811-2824`; `legion-fanout.sh:546-568`; `legion-router/scripts/delegate.sh:736-779` | Resolve once in fanout, emit that actual decision as evidence, and pass the immutable model/executor/sandbox/effort downstream. |
| 90 | Code-intel auto-detects a TypeScript project from any `.ts/.tsx`, then runs root `tsc --noEmit` even without a `tsconfig`. Legion Core itself has this shape. | `legion-code-intel/scripts/legion-code-intel.py:218-280` | Detect configured projects and run once per config; keep loose-file inference for explicit adapter use only. |
| 100 | Refresh starts `claude plugin list` once per installed plugin after updating the catalog. | `scripts/refresh.sh:121-139` | Capture the plugin list once after updates and query the saved output. |

### Low / opportunistic

- `legion-observability/scripts/legion-bench.py:1069-1113,2116-2146,2442-2496`
  gives corpus runs no retention and duplicates cases in two artifacts. Reuse
  the suite policy if corpus runs become operationally frequent. Confidence 90.
- `legion-self-learn.py:2453-2488,2584-2589` retains an unreachable
  `--apply-source` implementation. Delete it, optionally keeping a tiny
  deprecated-option error shim. Confidence 100.

## Simplify-rule conclusion

Core's final review prompt includes a generic instruction to focus on
unnecessary complexity, and routing mentions a simplification pass. That is
useful defense in depth, but the full tiered `simplicity-first` doctrine is a
optional catalog capability; duplicating that doctrine in Core would create a
second authority. The correct boundary is for an integrating catalog to select
the lens and for Core to execute the resulting review faithfully.

The review deliberately did **not** classify the four stage-specific context
compilations as duplicate work. They compile different frozen boundaries and
are bounded. Likewise, the two learning classifiers cannot simply be reduced
to one command today because their rule sets differ; only their discovery and
normalization work is safely shareable now.

## Recommended delivery order

1. Fix cancellation cleanup, fallback metering, and streaming backpressure.
2. Replace fanout batch barriers and remove repeated route resolution.
3. Make console and learning ingestion incremental/bounded.
4. Prune and consolidate Doctor/session/repository scans.
5. Remove unreachable source-mutation code and unify artifact retention.

## Verification

- Runtime-focused Python tests: 52 passed; one archive-only infrastructure
  failure expected a `.git` directory that `git archive` intentionally omits.
- Runtime Bats: 168 passed before the diagnostic cancellation run interrupted
  the next test; the interruption was not a product failure.
- Learning/observability Python tests: 277 passed.
- Learning/observability Bats: 39/39 passed.
- Focused Core Doctor/fanout Bats: 63/63 passed.
- Focused ShellCheck passed.
- `legion-doctor --repo .`: 0 failures, 0 warnings in the clean review snapshot.
- Independent confidence review retained the main runtime, routing, catalog,
  and learning findings and excluded the stage-specific context compiles.
