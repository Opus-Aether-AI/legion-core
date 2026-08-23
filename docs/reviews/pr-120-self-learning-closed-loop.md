# Ultra review — PR #120 `feat(learning): close the self-improvement loop`

- **Repo:** Opus-Aether-AI/legion-core
- **Diff:** `f9cd017...38beeca` (three-dot), 55 files, +8219 / −171
- **Mode:** report (read-only, no edits)
- **Shards:** 11 · **Reviewer agents:** 12 · **Lenses:** correctness+architecture, security+secrets, performance+observability, testing+regression, convention/AGENTS.md, release-safety, integration-coherence
- **Domain agents:** none (`.claude/agents/` is empty in this repo — domain lens skipped)
- **Gate:** confidence ≥ 80. Findings marked **CONFIRMED** were independently re-verified by the orchestrator by reading code or executing it; **PLAUSIBLE** rests on the reviewing agent's evidence only.

## Verdict

The plumbing is real and well built. The loop is genuinely closed end to end — evidence is
collected, promoted to typed hints, compiled per decision boundary, and interpolated into
prompts that executors actually receive. The isolation, fingerprinting, durable state machine,
rollback receipts and release surface are all of a high standard, and the release/packaging
shard came back clean on empirical checks.

The problem is what travels down the wire. For the entire `legion-run` evidence lane — the
lane this PR adds — every promoted hint carries the **same fixed boilerplate sentence**, and
because each failure mints a new hint with identical text and no content dedup, that
boilerplate saturates the token budget and evicts the genuinely learned cross-project laws.
The mechanism answers "is self-learning being used to improve outputs?" with *yes,
structurally* and *no, semantically*.

---

## Critical

**C1 — Every `legion-run` outcome promotes to the same information-free sentence** · CONFIRMED
`legion-observability/scripts/legion-self-learn.py:988-993`, `:1317-1320`

`legion-run` records outcomes with `source = f"legion-run:{stage}"` (`legion-run.py:1673`).
`_typed_hint_from_proposal` merges the real failure summary only for
`source in {"manual", "session-learn", "learning-law"}`; `legion-run:*` is not in that set, so
`guidance = suggested`, and `proposal_for_outcome`'s `else` branch hardcodes that string.

Four distinct stage failures produce four hints whose guidance is byte-identical:
`"Record the issue as a reusable harness memory and turn it into a source patch when it repeats
or blocks work."` A real failure — say an idempotency key not propagated to a retry path — is
computed, persisted in the outcome record, and then discarded at the promotion boundary. The
next run's planner is told nothing about it.

The docstring justifies the reduction as protection against "model-authored review prose", but
`legion-run:doctor`, `legion-run:validate` and `legion-run:fanout-apply` are deterministic tool
output, not model prose. The classification is inverted for three of the four stages.

**C2 — Boilerplate hints evict the genuinely learned laws** · CONFIRMED (mechanism)
`legion-observability/scripts/legion_learning_context.py:26`, `:279-295`

Hint IDs are `memory:{stable_id(proposal_id)}`, so N failures on one entity mint N distinct
hints sharing one guidance string. `_SCOPE_RANK` ranks `exact` (0) ahead of `global` (2), and
the selection loop has no dedup on guidance content. `legion-run.py:413` pins
`max_tokens: 1200`.

Executed: 30 boilerplate `exact` hints plus one real `global` law hint
("Always regenerate the OpenAPI client after changing a route contract") compiles to
`hint_count=11, token_count=1199`, **one distinct guidance string**, and the law hint excluded
with `exclusion_reason: "token_limit"`. After ~11 accumulated failures on an entity, no
genuinely learned guidance can reach any prompt again. The system gets *worse* at learning the
more it runs.

**C3 — Plan guidance is dropped on the `--plan-file` path while the receipt attests delivery** · CONFIRMED
`legion-orchestrate/scripts/legion-run.py:2570`, `:2577`, `:2597-2606`, `:1323-1390`

Line 2570 writes the guidance-appended task into `env["LEGION_TASK"]`. The shell-command
planner branch (2580-2587) passes `env` to `run_process` and does receive it. The
`--plan-file` branch calls `write_plan_from_files(..., task, ...)` at 2577 with the **raw**
`task`; that function is pure Python assembly that never reads `env` and sets
`payload["task"] = task` directly. Line 2596 then restores `env["LEGION_TASK"] = task`, so the
guidance is never read by anything.

`record_learning_receipt(..., "delivered" if plan_guidance else ...)` at 2597 fires regardless
of which branch ran. `learning-receipts.json` therefore attests delivery for a boundary where
the guidance was silently discarded — a guarantee reporting itself satisfied when it is not.

---

## High

**H1 — A bare phrase from the reviewer normalizes to a full zero-findings approve** · CONFIRMED
`legion-router/scripts/normalize-review-verdict.py:24-29`, `:138-145`

Verified by running the live regex: `looks good`, `No findings.`, `no issues`,
`nothing to flag` each match and are rewritten to
`{"verdict":"approve","summary":...,"findings":[]}`, which then passes `review_verdict_is_valid`
and satisfies `legion-improve.py:independent_review`. Richer variants correctly fail
(`"Overall it looks good."`, `"The patch is approved."`, `"LGTM"` → no match), so the regex is
anchored and narrow — but the narrow surface is real and is **new**: before this PR any
non-schema reviewer output hard-failed with `reason=invalid-verdict`. A reviewer model that
degrades to a terse phrase now silently satisfies the gate that authorizes a self-authored
patch to become a PR.

**H2 — A created PR can be left untracked, and recovery can open a second one** · PLAUSIBLE
`legion-observability/scripts/legion-improve.py:1489-1594`

`gh pr create --draft` returns 0 — the PR now exists on GitHub — but `pending_rollback` is only
persisted at 1584-1594, *after* parsing a bare URL from `lines[-1]`. A wrapper banner line, or
a crash in that window, leaves zero durable evidence of a real PR. Recovery relies on
`gh pr list --head <branch> --state all`; if that returns rc=0 with an empty list (GitHub list
eventual-consistency, or any transient hiccup), execution falls through to an unconditional
push + `gh pr create`, opening a second PR for the same fingerprint.

**H3 — An unreadable `laws.json` is treated as "every law retired"** · PLAUSIBLE
`legion-observability/scripts/legion-self-learn.py:1110-1184`, `:660-678`, `:1382-1417`

`learning_law_lifecycle()` returns `{}` on any `None` read. `has_lifecycle` is always true, so
the reconciliation loop runs and `lifecycle.get(law_key) != "active"` is trivially true for
every entry — `os.unlink`ing every `improvement-queue/*.json` entry with
`provenance.source == "learning-law"`. The same condition flips every previously promoted
law-scoped hint to `status="retired"`, which `_match_reason` then excludes from compiled
context. Triggered by a fresh install before analyze has run, a repointed
`LEGION_GLOBAL_LEARNING_DIR`, or a pruned `~/.legion`. Not gated behind `--apply-memory`.

**H4 — A corrupt or oversized `hints.json` is silently overwritten** · PLAUSIBLE
`legion-observability/scripts/legion-self-learn.py:1356-1472`

`read_bounded_json` returns `None` for oversized (>1 MB), truncated, or wrong-shaped documents.
`_dict(existing)` reduces that to `{}`, so both `maintainers` and `generated` start empty, and
line 1472 unconditionally commits only this run's hints as the new source of truth. Every
previously stored maintainer-curated hint is lost with no error, warning, or backup —
contradicting the function's own docstring ("without overwriting maintainer-owned hints").

**H5 — `advisory` mode aborts the whole run when the compiler misbehaves** · PLAUSIBLE
`legion-orchestrate/scripts/legion-run.py:2233-2253`, `:2266-2293`

Both the process-failure and contract-validation branches re-raise unconditionally with no
branch on `learning_context_mode`. Only the exact stub output `{"ok": True}` is treated as a
soft "unavailable". So in the default `advisory` mode a transient fault in the separate
`legion-self-learn` subsystem fails the entire heavy-task run before `plan` executes,
contradicting the documented non-blocking guarantee.

**H6 — `maintainer_eligible: true` is the only unconditional eligibility gate** · CONFIRMED
`legion-observability/scripts/legion-improve.py:336-337`, `:373-374`

The documented evidence bar (confidence ≥ 0.9, ≥5 episodes, ≥3 projects,
`docs/self-learning.md:224-227`) lives inside `if provenance is not None:`. Omit the
`provenance` key entirely and the whole block is skipped. `provenance` is **not** in the
proposal schema's `required` array (verified: `["schema","id","revision","maintainer_eligible",
"kind","summary","target","candidate","validation"]`), so such a proposal is schema-valid *and*
passes `validate()`. Enforcement rests entirely on the producer; the consumer's defense-in-depth
check is opt-in by the untrusted document itself.

**H7 — `legion-improve` resolves its dependencies off `PATH`, which cron does not have** · PLAUSIBLE
`legion-observability/scripts/legion-improve.py:1140-1143`, `:1449-1452`

`independent_review` uses `shutil.which("legion-delegate")` and `draft` uses
`shutil.which("gh")`, while `refresh.sh` deliberately invokes every other Legion binary by
absolute `$SOURCE_CLONE/...` path — the authors clearly knew PATH is unavailable there.
`legion-improve.py` has no `COMMAND_FALLBACKS` equivalent to `legion-run.py:118-128`. Under the
installed cron, every proposal terminates `failed / independent_review_unavailable`, silently,
forever (stdout/stderr are discarded by the cron line).

---

## Medium

| # | Finding | Location |
|---|---|---|
| M1 | `changed_paths` never checks `returncode`; on the 2 MB output cap `_bounded_process` returns **empty** stdout, whose digest equals `EMPTY_DIFF` — so the `baseline_mutated` tamper check reads a large real mutation as "no mutation" | `legion-improve.py:981-1005`, `:181-199`, `:1049-1050` |
| M2 | A **CLOSED or MERGED** PR matching branch/base/head/body is adopted as a successful terminal `draft_created`; `_pr_identity_error` never inspects `state`, though `_owned_open_draft` proves it is available | `legion-improve.py:1267-1322` |
| M3 | The artifact manifest hashes only `run_dir` top level (`iterdir`, not `rglob`), so the 9 files under `learning-contexts/` for the fanout/validate/review boundaries carry no SHA-256 — post-run edits to what the reviewer was told leave no discrepancy | `legion-run.py:1479-1496` |
| M4 | `apply_candidate` does `reset --hard` but no `git clean` (unlike `ensure_worktree`), so a temp file orphaned by a crash is later seen by `git ls-files --others` and durably rejects the proposal as `path_not_allowlisted` — a non-retryable terminal state | `legion-improve.py:944`, `:986-992` |
| M5 | "At most one draft PR per refresh" is a property of passing `--max 1`, not an enforced invariant; nothing caps drafts *created* per invocation, and the docs sanction raising `LEGION_IMPROVE_MAX`. Holds at shipped defaults (argparse bounds `--max` to 1..10, default 1) | `legion-improve.py:2032-2091`, `:2131` |
| M6 | A fingerprint with an unrecoverable `pending_rollback` sorts first every run and consumes the entire `--max 1` budget, starving all later queue entries indefinitely | `legion-improve.py:2032-2069` |
| M7 | `reconcile_state` reads legacy state with the **unbounded** `read_json` and merges `evidence_ids` with no cap, bypassing `MAX_EVIDENCE_RECORDS`/`MAX_IDENTIFIER_CHARS`; `safe_legacy_identity` authorizes the merge on **basename only**, so `github.com/acme/release-tools` matches an unrelated `/other/org/checkout/release-tools` | `legion_learning_context.py:386-423`, `:316-323` |
| M8 | Only `legion-run` compiles and injects context. `legion-delegate` / `legion-fanout` / `legion-orchestrate` — the paths `AGENTS.md` directs agents to for ordinary work — receive no guidance and never feed the loop | `legion-run.py:2182-2350` (sole consumer) |
| M9 | Nothing anywhere writes `global_learning_dir/hints.json`, yet `GLOBAL_HINT_RESERVE` permanently reserves 100 compiler slots for it, evicting project hints earlier for no benefit | `legion-self-learn.py:57-62`, `:1356-1362` |
| M10 | `learning-context-receipt.json` is declared in `PIPELINE_REQUIRED_ARTIFACTS` but is written only inside `compile_learning_context`; a `doctor` or `self-learn-hints` stage failure produces a run dir missing a mandatory artifact, and `finalize_failure` never writes it | `legion-run.py:61`, `:2130`, `:2201` |
| M11 | Untested invariants that would ship green if regressed: approve-with-blocking-findings (`blocked_finding` never exercised — the reviewer fixture always emits `findings:[]`); `_reviewed_head_matches` (zero references in the suite); post-apply allowlist mismatch; refusal to delete an unowned branch; missing reviewer binary; and the `_github_repository` URL-parsing fallback (every test pins `LEGION_IMPROVE_GITHUB_REPOSITORY`) | `test_legion_improve_contract.py` |
| M12 | No end-to-end test runs the real chain from a written `hints.json` through the real compiler into a prompt. `install_learning_context_boundary_fake` shadows `legion-self-learn` with a stub emitting curated fixture text, so C1 (100% boilerplate promotion) is invisible to the entire suite. No test asserts the marker `"Trusted learning guidance (bounded)"` against real promoted guidance | `tests/legion-run.bats:211-300`; `test_legion_self_learn.py:941` |

---

## Dropped below the gate (and why)

- **"Trust is a self-asserted boolean → prompt injection"** — requires an attacker who can already
  write `hints.json` in the local state root, which is game-over independently. All guidance
  sources are fixed tables: `LAW_GUIDANCE` (`legion_learning.py:227`), `RULES`
  (`legion-session-learn.py:89`), and review findings reduced to a fixed guardrail. The only
  free-text path is `source="manual"` via the operator's own `--summary`. Defense-in-depth note,
  not a finding.
- **Normalizer fail-open cases untested** — refuted. `tests/legion-router.bats` covers prose
  normalization and contradictory verdicts; the `APPROVAL` regex is anchored, not a loose
  `contains("approved")`.
- **Markdown-fenced JSON verdict accepted** — intentional robustness for a documented Codex
  quirk; the unwrapped payload is still a schema-valid structured verdict.
- **`export LEGION_IMPROVE_MODE` invisible to cron** — real, but the pattern pre-dates this PR
  (`LEGION_HEAL=1`, verified against the base SHA). Advisory, not introduced here. Note it still
  gates a headline new capability.
- **npm surface / exec bits / schema-constant drift / plugin versions** — all checked
  empirically and clean (`npm pack --dry-run`, `git ls-tree`, `shellcheck`, `legion-doctor`:
  0 fail / 0 warn).
- **Unicode bidi characters accepted in guardrail text**, **durable-record ids are unkeyed
  digests**, **`read_json` misses `MemoryError`/`RecursionError`**, **queue 1000-entry cap
  truncates in filesystem order**, **`exclusion_reason` mislabels count-capped hints as
  `token_limit`** — real but low impact; listed for completeness.
- **`legion.learning-proposal.v1.schema.json` has no producer or consumer** — inert, not broken.

---

## Suggested order of work

1. **C1** — add a `legion-run:*` branch to `proposal_for_outcome` / `_typed_hint_from_proposal`
   so deterministic tool output carries its real summary. Without this the feature is
   structurally complete and semantically empty.
2. **C2** — dedup on guidance content before the budget loop, and let `global` law hints reserve
   space ahead of repeated `exact` boilerplate.
3. **C3** — pass `env["LEGION_TASK"]` (or the guidance explicitly) into `write_plan_from_files`,
   and make the receipt reflect the branch actually taken.
4. **H1** — drop the bare-phrase approval path, or bind it to a schema verdict.
5. **H3/H4** — distinguish "could not read state" from "state says inactive/empty"; make both
   destructive paths no-ops on read failure. One root cause, two criticals' worth of blast radius.
6. **H7** — give `legion-improve` the same in-repo `COMMAND_FALLBACKS` treatment `legion-run` has.
7. **M12** — one end-to-end test from a written `hints.json` to an asserted prompt string would
   have caught C1, C2 and C3 together.
