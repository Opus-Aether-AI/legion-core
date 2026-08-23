### Ultra review

`legion-core` PR #115

Target: `main...feat/evidence-learning-v2`  
Reviewed head: `4a505a0178a546cc326a6b1c9d6f2baaff425a83`  
Mode: report  
Classification: feature PR on a single-trunk repository; release-safety lens applied conservatively.

## Review plan

| Shard | Surface | Files | Applied lenses |
|---|---|---:|---|
| C1 | Evidence engine, CLI, state identity, schemas | 10 | correctness, security, performance/observability, testing, conventions, release-safety |
| C2 | Self-learning, refresh, package and plugin integration | 5 | correctness, security, performance/observability, testing, conventions, release-safety |
| C3 | Python, Bats, and npm regression tests | 5 | test correctness, regression risk, conventions, release-safety |
| C4 | User and integration documentation | 4 | contract correctness, conventions, release-safety |

No repository-specific domain agents were discovered. The four shards were reviewed in two parallel map waves. Candidate findings were then deduplicated and verified by three fresh confidence-scoring batches using the protocol's verbatim rubric and false-positive catalog. Only scores of 80 or higher survived.

## Findings

### High

1. **`--repo-only` can mix durable excerpts from unrelated repositories with the same basename** — correctness and data-boundary security, confidence **95**.
   `_project_for_cwd` discards the owner portion of the normalized remote, so `org-a/service` and `org-b/service` both become `service`; filtering then accepts both. A focused two-repository repro confirmed the collision.
   https://github.com/Opus-Aether-AI/legion-core/blob/4a505a0178a546cc326a6b1c9d6f2baaff425a83/legion-observability/scripts/legion_learning.py#L395-L403

2. **The durable-report redaction boundary leaves common secrets and absolute paths intact** — security and secrets, confidence **95**.
   Direct probes preserved standalone Slack `xoxb-...` credentials, PEM private-key material, and Linux paths such as `/root/...` and `/var/lib/...`; normalization then stores the resulting excerpt.
   https://github.com/Opus-Aether-AI/legion-core/blob/4a505a0178a546cc326a6b1c9d6f2baaff425a83/legion-observability/scripts/legion_learning.py#L289-L345

3. **The project-ID change makes existing default state invisible after upgrade** — release-safety and compatibility, confidence **100**.
   The previous implementation hashed the absolute checkout path; this PR hashes the normalized remote whenever `origin` exists. There is no migration or fallback, so existing spans, registry, reports, benchmarks, and learning state resolve under a different directory.
   https://github.com/Opus-Aether-AI/legion-core/blob/4a505a0178a546cc326a6b1c9d6f2baaff425a83/legion-observability/scripts/legion_state.py#L115-L120

### Medium

4. **Outcome regexes invert negated statements** — correctness, confidence **95**.
   Focused probes classify statements such as "Tests did not pass" and "CI is not green" as verified, while "Validation did not fail" becomes failed; `_outcome_for` records the match with high confidence.
   https://github.com/Opus-Aether-AI/legion-core/blob/4a505a0178a546cc326a6b1c9d6f2baaff425a83/legion-observability/scripts/legion_learning.py#L306-L315

5. **Actual Codex `spawn_agent` calls are omitted from dispatch evidence** — performance and observability, confidence **100**.
   Codex stores calls as top-level `response_item` payloads containing `function_call`; `_dispatches` only reads `message.content[]`, so dispatch metadata and execution-leverage scoring miss real Codex delegation.
   https://github.com/Opus-Aether-AI/legion-core/blob/4a505a0178a546cc326a6b1c9d6f2baaff425a83/legion-observability/scripts/legion_learning.py#L473-L499

6. **The default daily scan has no aggregate file, byte, or event bound** — performance, confidence **88**.
   The size limit applies per JSONL file, while every eligible file and normalized event is accumulated in memory. The refresh path supplies no aggregate limit; the current three-day fixture already spans tens of megabytes and growth is unbounded.
   https://github.com/Opus-Aether-AI/legion-core/blob/4a505a0178a546cc326a6b1c9d6f2baaff425a83/legion-observability/scripts/legion_learning.py#L1049-L1091

7. **Evolving law revisions can hide the newest guidance behind stale hints** — correctness, confidence **95**.
   Support-dependent summaries and evidence create new outcome/proposal/hint identities. Memory preserves each revision, while hint rendering emits the oldest five; because every law targets the same plugin, current guidance can be crowded out.
   https://github.com/Opus-Aether-AI/legion-core/blob/4a505a0178a546cc326a6b1c9d6f2baaff425a83/legion-observability/scripts/legion-self-learn.py#L587-L619

8. **Advertised cost and token regression gates cannot fire** — correctness and documented contract, confidence **98**.
   Real scorecards hard-code both values to zero for baseline and candidate, so listing them in `compare_scorecards` does not measure or gate either regression.
   https://github.com/Opus-Aether-AI/legion-core/blob/4a505a0178a546cc326a6b1c9d6f2baaff425a83/legion-observability/scripts/legion-self-learn.py#L764-L774

9. **Historical snapshots prevent unsupported laws from retiring** — correctness and lifecycle, confidence **100**.
   The code says it loads the latest reports but reads every project-day snapshot. Historical episode IDs therefore remain in support forever, so `merge_law_store` never sees an absent key to retire.
   https://github.com/Opus-Aether-AI/legion-core/blob/4a505a0178a546cc326a6b1c9d6f2baaff425a83/legion-observability/scripts/legion_learning.py#L1101-L1114

### Low

10. **An episode can be verified while its decision link is failed** — report consistency, confidence **98**.
    Episode status checks all events and gives any verified match precedence over failure. A `tests passed` event followed by `validation failed` produces a verified episode and a failed latest outcome link.
    https://github.com/Opus-Aether-AI/legion-core/blob/4a505a0178a546cc326a6b1c9d6f2baaff425a83/legion-observability/scripts/legion_learning.py#L854-L866

11. **The new default-state test leaks the two new learning-directory overrides** — test isolation, confidence **95**.
    A legitimate `LEGION_PROJECT_LEARNING_DIR` or `LEGION_GLOBAL_LEARNING_DIR` in the environment makes the default-path assertions fail because setup clears the older state variables but not the new ones.
    https://github.com/Opus-Aether-AI/legion-core/blob/4a505a0178a546cc326a6b1c9d6f2baaff425a83/tests/python/test_legion_state.py#L40-L45

## Confidence-gate disposition

Eleven findings survived. Five generic test-coverage candidates were discarded at confidence 20–45 under the protocol's false-positive catalog: missing non-Codex fixtures, a duplicate redaction-test gap, missing refresh failure-branch coverage, an incomplete law-promotion assertion, and per-metric scorecard coverage.

## Validation evidence

- GitHub CI: all eight `legion-core` checks passed.
- Local validation before review: 489 Bats tests and 270 Python tests passed.
- ShellCheck, staged Gitleaks, diff hygiene, and `legion-doctor` passed; doctor reported 0 failures and 0 warnings.
- Focused review repros confirmed repository-name collisions, redaction misses, negation inversion, Codex dispatch omission, state-path migration, stale-hint ordering, law non-retirement, and episode/link inconsistency.

This is a report-mode review. No source fixes were applied by the ultra-review.

🤖 Generated with [Claude Code](https://claude.ai/code)
