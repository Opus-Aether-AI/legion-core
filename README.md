<div align="center">
  <img src="./identity/legion-banner.png" alt="Legion" width="720">
</div>

<p align="center">
  <a href="https://legion.opusaether.com"><img alt="site" src="https://img.shields.io/badge/site-legion.opusaether.com-c7a24e?logo=vercel&logoColor=white"></a>
  <a href="https://www.npmjs.com/package/@opus-aether-ai/legion-core"><img alt="npm" src="https://img.shields.io/npm/v/@opus-aether-ai/legion-core?logo=npm&label=npm&color=cb3837"></a>
  <a href="https://github.com/Opus-Aether-AI/legion-core/actions/workflows/legion-ci.yml"><img alt="ci" src="https://img.shields.io/github/actions/workflow/status/Opus-Aether-AI/legion-core/legion-ci.yml?branch=main&label=ci&logo=github"></a>
  <a href="LICENSE"><img alt="license" src="https://img.shields.io/github/license/Opus-Aether-AI/legion-core?label=license&color=6e5494"></a>
</p>

> **legion-core** is the model-agnostic execution layer for AI coding agents: scoped routing and delegation, isolated worktrees, evidence, observability, and learning loops.

It is the reusable core behind Legion agents, not a domain agent itself. Use it directly for disciplined coding work or build a domain plugin on its execution contract.

## Install and update

Use the installer, not a hand-assembled global package setup. It installs the marketplace, shared CLIs, cross-harness skills, and the selected bridges. It is idempotent and installs the latest published release by default.

```bash
curl -fsSL https://raw.githubusercontent.com/Opus-Aether-AI/legion-core/main/scripts/install.sh | bash -s all
```

From a clone, run `bash scripts/install.sh all`. The installer needs `curl`, `jq`, and `git`; Claude Code is optional. Re-run the installer safely, or use the installed command to update:

```bash
legion-setup update
legion-setup status
```

For CLI-only use, the published npm package is also available:

```bash
npm install -g @opus-aether-ai/legion-core
```

Use `LEGION_REF=main` for the current main branch or `LEGION_REF=<tag>` to pin
the bootstrap snapshot. Manual/daily refresh intentionally advances the managed
source clone to `origin/main`; disable cron when maintaining a frozen snapshot.
`minimal` installs router and observability; pass a plugin name to install just
that plugin.

## Harness support

Legion supports Claude Code, Codex CLI, Cursor Agent, opencode, Hermes, and
generic `AGENTS.md`-aware harnesses. The installer sets up shared skills under
`~/.agents/skills` and CLI links under `~/.agents/bin`; then wire the native
harness bridges you use:

```bash
legion-setup codex
legion-setup cursor
legion-setup opencode
```

Each command has a read-only `verify` form. Codex gets MCP registration and a
skill mirror; Cursor gets MCP and command/agent bridges; opencode gets its MCP
bridge. Restart the relevant harness after setup. Claude Code uses the
marketplace directly; Hermes consumes `legion-hermes-mode` from its skills
directory.

Make Legion the default in an existing repository without replacing its
instructions:

```bash
legion-init --repo .
legion-init --repo . --check
```

`legion-init` resolves the Git root, serializes mutations, transactionally
updates versioned blocks in `AGENTS.md` and `CLAUDE.md`, and preserves every
unmanaged byte. Its policy also tells delegated children to implement directly,
preventing recursive Legion calls. `--check` and `--dry-run` remain read-only;
use `--remove` for an exact rollback. `legion-setup init` is the same entrypoint.

## The nine plugins

| Plugin | Purpose |
|---|---|
| `legion-router` | Routes scoped work to configured executors and captures metered, reviewable diffs. |
| `legion-observability` | Doctor, spans, reports, benchmarks, evidence-linked learning, and heal planning. |
| `legion-orchestrate` | Decomposition, parallel fan-out, cross-review, synthesis, and gates. |
| `legion-run` | Evidence-backed lifecycle for substantial tasks. |
| `legion-setup` | Marketplace installation, updates, and harness bridges. |
| `legion-codex-mode` | Codex-primary routing guidance, including when to ask Claude. |
| `legion-opencode-mode` | opencode-primary routing and delegation guidance. |
| `legion-hermes-mode` | Metered delegation guidance for Hermes-driven coding work. |
| `legion-code-intel` | Optional TypeScript and Pyright diagnostic artifacts. |

## Use the smallest useful surface

| Need | Start with |
|---|---|
| One scoped implementation or independent review | `legion-delegate run` / `legion-delegate review` |
| Parallel independent slices | `legion-fanout` |
| Multi-step work requiring decomposition and cross-checks | `legion-orchestrate` |
| A substantial task with explicit plan, validation, and evidence | `legion-run` |
| Health, cost, reports, or future-run hints | `legion-doctor`, `legion-report`, `legion-learn`, `legion-self-learn` |

Check a repository before work:

```bash
cd /path/to/repo
legion-doctor --repo .
legion-state --repo .
```

For heavy work, `legion-run` records doctor results, prior hints, plan/slices, routing and fan-out, review, validation/evaluation, reports, learning feedback, and a heal plan. Model output is evidence to verify, not success by itself. See [legion-run](legion-run/README.md) and [domain plugins](docs/domain-plugins.md) for the complete contract.

## Delegation stays reviewable

`legion-delegate` and `legion-cursor` run work in isolated git worktrees and return a diff for review. Claude delegation now follows the same contract:

```bash
legion-claude run --repo . --task "Review the current implementation for correctness"
```

For a git repository, `legion-claude` creates `<repo>/.legion/worktrees/<run-id>` and preserves the patch at `<repo>/.legion/runs/<run-id>/diff.patch`. It removes the temporary worktree by default; use `--keep` to retain it or `--apply` only after reviewing the patch. When Claude is unavailable or rate-limited, it can fall back to the configured Codex executor unless `--no-fallback` is supplied.

## State and artifacts

By default, project state is outside the repository at `~/.legion/projects/<repo-id>/` (where `<repo-id>` includes a path hash). It contains spans, registry data, benchmarks, and reports. Per-run review artifacts remain with the repository under `.legion/runs/`; transient isolated worktrees are under `.legion/worktrees/`.

Override state with `LEGION_STATE_ROOT`, `LEGION_HOME`, or `[state].root` in `.legion/config.toml` (or `~/.config/legion/config.toml`). `legion-state --repo .` prints the resolved paths. Global logs resolve through `LEGION_LOG_ROOT`, `XDG_STATE_HOME/legion`, an existing legacy Claude log directory, or `~/.legion/logs`.

## Contributing

Keep the core domain-neutral, add focused tests, and run:

```bash
bats tests/
tests/python/run-tests.sh tests/python
legion-observability/bin/legion-doctor --repo .
shellcheck $(git ls-files '*.sh')
```

Read [CONTRIBUTING.md](CONTRIBUTING.md) for current follow-ups and [AGENTS.md](AGENTS.md) for repository policy.

## More documentation

- [Build a domain plugin](docs/domain-plugins.md)
- [Build an agent on Legion Core](docs/building-an-agent.md)
- [Self-learning and heal loop](docs/self-learning.md)
- [Benchmarking](docs/benchmarking.md)
- [Sync with Legion Code](docs/sync-with-legion-code.md)

## License

[Apache-2.0](LICENSE). Enterprise support and pilots: [ENTERPRISE.md](ENTERPRISE.md).
