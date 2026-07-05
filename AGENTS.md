# AGENTS.md — legion-core orientation for Codex, Cursor, and other non-Claude harnesses.

`legion-core` is the model-agnostic orchestration engine behind Legion: routing, delegation, observability, setup bridges, and Codex-mode guidance.

## Plugin map

- `legion-router`: delegate scoped work to Codex/Cursor/Claude-side executors using routing policy, isolated worktrees, and telemetry.
- `legion-orchestrate`: decompose a larger coding goal, fan out parallel slices, cross-verify, then synthesize.
- `legion-observability`: inspect cost/latency/success, validate `legion.span.v1`, run `legion-doctor`, and drive self-learn/heal loops.
- `legion-code-intel`: run optional repo-native TypeScript/Pyright diagnostics, changed-file gates, and code-intelligence telemetry.
- `legion-setup`: install/update the marketplace and wire Codex/Cursor bridges plus shared skills/bins.
- `legion-codex-mode`: Codex-primary routing guidance for when to stay inline vs call Claude.

## Working here

- Tests: this repo has no `package.json` scripts; use `bats tests/` for the shell suite and targeted runs like `bats -f cron tests/`.
- Validation: `legion-observability/bin/legion-doctor` is the local health gate; CI also runs workflow checks under `.github/workflows/`.
- Branch model: work on a feature branch and open PRs against `main`.

## See also

- Contributor rules and local verification: [CLAUDE.md](CLAUDE.md)
- Repo overview and install/runtime context: [README.md](README.md)
- Longer docs and build recipes: [docs/](docs/)
