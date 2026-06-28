# Credits

legion-core is original integration code from Opus Aether AI. It was built in
conversation with a fast-moving agent-harness ecosystem, and this file records
the projects, papers, standards, and tools that shaped the design.

Credit here does not imply endorsement, sponsorship, or bundled source code.
Unless a file carries its own notice, implementation code in this repository is
original to legion-core.

## Agent harness research and prior art

- [svineet/harness-bench](https://github.com/svineet/harness-bench) shaped the
  workbench framing for creating, observing, analyzing, and auto-improving agent
  harnesses.
- [nyosegawa/harness-bench](https://github.com/nyosegawa/harness-bench)
  influenced the practical CLI-agent benchmarking mindset for Codex,
  Claude Code, and Cursor Agent debugging runs.
- [Karpathy's autoresearch](https://github.com/karpathy/autoresearch) influenced
  `legion-self-learn`'s bounded experiment loop: baseline, isolate, mutate,
  score, keep measured improvements, and discard regressions.
- [neosigmaai/auto-harness](https://github.com/neosigmaai/auto-harness) is
  adjacent prior art for mining failures, optimizing an agent harness, and
  gating changes against regressions.

## Benchmark corpora

- [Aider-AI/polyglot-benchmark](https://github.com/Aider-AI/polyglot-benchmark)
  (MIT; Exercism content) is imported as the external `aider-polyglot-python`
  corpus by `legion-observability/bench/tools/import-aider-polyglot.py`, pinned
  to commit `7e0611e77b54e2dea774cdc0aa00cf9f7ed6144f`. The corpus is a
  deterministic transform (regenerate by re-running the importer); reference
  solutions become `answer_files` only for the no-spend scripted-oracle control.
- [SWE-bench](https://github.com/swe-bench/SWE-bench) is the model for the planned
  repository-level live adapter (per-instance Docker harness).

## Protocols, runtimes, and interfaces

- [Model Context Protocol](https://modelcontextprotocol.io/) makes the portable
  plugin/tool-server model practical across agent clients.
- [OpenAI Codex CLI](https://github.com/openai/codex),
  [Claude Code](https://code.claude.com/docs/en/overview), and
  [Cursor CLI](https://cursor.com/docs/cli/overview) are the agent runtimes
  Legion targets and tests against.
- [OpenTelemetry](https://opentelemetry.io/) shaped Legion's durable trace and
  span model for observable agent work.
- [`@ai-hero/sandcastle`](https://www.npmjs.com/package/@ai-hero/sandcastle)
  is the optional container sandbox backend used by the delegated-run sandbox
  path.

## Developer and release tooling

Legion's local validation and packaging lean on:

- [Bats](https://bats-core.readthedocs.io/) for shell test coverage.
- [ShellCheck](https://www.shellcheck.net/) for shell static analysis.
- [jq](https://jqlang.github.io/jq/) for JSON handling in scripts.
- [GitHub CLI](https://cli.github.com/) for issue, PR, release, and workflow
  automation.
- [Bun](https://bun.sh/) and [npm](https://www.npmjs.com/) for package and
  release workflows.
- [Python](https://www.python.org/) for observability, routing, and catalog
  helper scripts.
- [Git](https://git-scm.com/) for worktree-based delegation and reproducible
  diff handling.

## Provenance

legion-core was extracted from the broader Legion marketplace and sanitized into
a reusable, model-agnostic engine. See [CONTRIBUTING.md](CONTRIBUTING.md) and
[docs/building-an-agent.md](docs/building-an-agent.md) for the current project
boundaries.

## Adding credits

When a new paper, project, standard, runtime, or tool materially shapes Legion,
add it here with a link and a short note describing the influence. Keep the note
specific enough that future maintainers can tell whether the credit is for
research framing, runtime compatibility, protocol design, test tooling, or
packaging.
