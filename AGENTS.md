# AGENTS.md — legion-core repository policy

This is the canonical, harness-neutral policy for every agent working in
`legion-core`. Read and follow it before making a change. Harness-specific
instruction files may add an overlay, but must not duplicate or override this
policy.

`legion-core` is the reusable, model-agnostic orchestration core behind Legion:
routing, delegation, observability, setup bridges, and harness guidance.

## Scope

- This repository contains the `legion-*` plugins, schemas, configuration,
  install/bridge scripts, and the `bats` test suite.
- Domain agents (trading, research, and similar) build on top of this project;
  do not add domain-specific plugins, skills, or copy here.

<!-- legion:init:v1:agents:start -->
<!-- legion:init:v1:padding-before=0;padding-after=0;created=0;eol=lf;sha256=4a1ef5458c3b1ca4 -->
## Legion workflow

Legion is the mandatory default operating mode for coding tasks in this
repository, regardless of which compatible harness is active. “Default” means
enter the appropriate Legion mode; it does not mean every tiny action must be
delegated.

- If `LEGION_ACTIVE=1`, `LEGION_DEPTH` is positive, or the working directory is
  under `.legion/worktrees/`, this process is already a delegated executor:
  implement the assigned slice directly unless it needs a bounded, explicit
  cross-harness handoff. Use only `legion-delegate run --executor <different
  coding harness>` for that handoff; Legion keeps task scanning, isolation,
  telemetry, and `LEGION_MAX_DEPTH` (default `2`) intact. Do not invoke raw
  harness CLIs or implicit/same-harness nested delegation. Return to the parent
  if the slice needs re-planning.
- Otherwise, before editing, invoke the applicable installed Legion skill or
  command and read relevant `legion-self-learn hints`.
- When `.legion/legion-core.json` exists, its exact version and release commit
  are this repository's declared Legion baseline. Update that managed pin only
  through the Legion release workflow.
- Use `legion-run` for substantial or multi-stage work that needs an explicit
  plan, deterministic validation, independent review, and retained evidence.
- Use `legion-orchestrate` or `legion-fanout` for dependency-aware parallel
  slices; use `legion-delegate` for scoped delegation and independent review.
- Do not call raw `claude`, `codex`, `agent`, or `opencode` processes for
  delegated coding work. Go through Legion so isolation, routing, telemetry,
  and review contracts remain active.
- Inline work is allowed only when the active Legion harness-mode guidance
  selects it. It still follows this repository's tests and health gates.
- Primary sessions stop on semantic convergence, not an elapsed-time or retry
  deadline. At each material checkpoint, use `legion-converge` to classify the
  workflow as `actionable`, `complete`, `waiting_external`, or `blocked`.
  Continue only from `actionable` with new source or failure evidence. Yield on
  `complete` or `waiting_external`; external checks can resume the work when
  their state changes. Yield and report `blocked`.
  Treat repeated same source and evidence fingerprints as no progress. Do not
  rerun the same validation on an unchanged tree, repeat review on the same
  immutable head, or reopen work solely for non-blocking suggestions.
- If Legion is unavailable or blocked, stop and report the blocker instead of
  silently bypassing it.
<!-- legion:init:v1:agents:end -->

## Plugin map

- `legion-router`: scoped delegation across Claude, Codex, Cursor, opencode,
  Hermes, and Pi with routing policy, isolated worktrees, and telemetry.
- `legion-orchestrate`: decompose a larger coding goal, fan out parallel slices,
  cross-verify, then synthesize.
- `legion-run`: execute substantial tasks through the plan, route, fan-out,
  validation, review, evidence, learning, and heal lifecycle.
- `legion-observability`: inspect cost/latency/success, validate
  `legion.span.v1`, run `legion-doctor`, and drive self-learn/heal loops.
- `legion-code-intel`: optional repo-native TypeScript/Pyright diagnostics,
  changed-file gates, and code-intelligence telemetry.
- `legion-setup`: install/update the marketplace, manage repo instruction
  blocks with `legion-init`, wire Codex/Cursor/opencode bridges, and verify
  Pi shared-skill readiness plus Hermes's managed native discovery link.
- `legion-codex-mode`: Codex-primary routing guidance for choosing inline work
  versus Claude delegation.
- `legion-opencode-mode`: opencode-primary routing and delegation guidance.
- `legion-hermes-mode`: symmetric primary/coding guidance for Hermes-driven work.
- `legion-pi-mode`: symmetric primary/coding guidance for Pi-driven work.

## Editing rules

1. Keep `.claude-plugin/marketplace.json` and each
   `<plugin>/.claude-plugin/plugin.json` version in sync; bump both on a plugin
   change.
2. Skill frontmatter must contain strict `name` and `description` fields; keep
   `description` on one line (no block scalars—`legion-doctor` enforces this).
   Frontmatter must also parse as YAML: quote any value containing `": "`, or
   strict loaders reject the document and drop the skill entirely.
3. Bash is the lingua franca; scripts must pass `shellcheck`.
4. Do not commit secrets. Gitleaks gates CI; credentials belong in the
   environment or Keychain.
5. Telemetry must conform to
   `legion-observability/schema/legion.span.v1.schema.json`. New executors emit
   spans through `legion-trace emit` to keep the stream uniform.

## Verification and delivery

- This repository has no `package.json` scripts. Run `bats tests/` for the shell
  suite; target a subset with commands such as `bats -f cron tests/`.
- Run `tests/python/run-tests.sh tests/python` for the Python suite.
- Run `legion-observability/bin/legion-doctor` as the local health gate.
- Run `shellcheck $(git ls-files '*.sh')` for shell changes.
- CI also runs workflow checks under `.github/workflows/`.
- Work on a feature branch and open pull requests against `main`. PR titles and
  commit subjects must use a configured Conventional Commit type so squash and
  rebase merges both remain compatible with Release Please.

## Reference material

- Repository overview and install/runtime context: [README.md](README.md)
- Longer docs and build recipes: [docs/](docs/)
- Claude Code overlay: [CLAUDE.md](CLAUDE.md)
