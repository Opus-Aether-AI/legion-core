<div align="center">
  <img src="./identity/legion-banner.png" alt="" width="720">
</div>

<p align="center">
  <a href="https://legion.opusaether.com"><img alt="site" src="https://img.shields.io/badge/site-legion.opusaether.com-c7a24e?logo=vercel&logoColor=white"></a>
  <a href="https://www.npmjs.com/package/@opus-aether-ai/legion-core"><img alt="npm" src="https://img.shields.io/npm/v/@opus-aether-ai/legion-core?logo=npm&label=npm&color=cb3837"></a>
  <a href="https://github.com/Opus-Aether-AI/legion-core/releases"><img alt="release" src="https://img.shields.io/github/v/release/Opus-Aether-AI/legion-core?display_name=tag&label=release&color=2ea043"></a>
  <a href="https://github.com/Opus-Aether-AI/legion-core/actions/workflows/legion-ci.yml"><img alt="ci" src="https://img.shields.io/github/actions/workflow/status/Opus-Aether-AI/legion-core/legion-ci.yml?branch=main&label=ci&logo=github"></a>
  <a href="LICENSE"><img alt="license" src="https://img.shields.io/github/license/Opus-Aether-AI/legion-core?label=license&color=6e5494"></a>
  <img alt="agents" src="https://img.shields.io/badge/agents-Codex%20%C2%B7%20Claude%20%C2%B7%20Cursor%20%C2%B7%20opencode-8a2be2">
</p>

> **legion-core** — the model-agnostic orchestration engine behind Legion. The base layer you build your own agents on.

One will commands a host of agents — **GPT-5.x via Codex**, **Cursor**, **Claude** (and humans). legion-core gives you the parts that aren't domain-specific: scoped multi-model **delegation**, **telemetry**, a **health check**, **self-learning**, and **auto-healing** — so a new agent project starts from a working spine instead of a blank page.

```bash
curl -fsSL https://github.com/Opus-Aether-AI/legion-core/releases/latest/download/install.sh | bash
```

## What's inside (5 plugins)

| Plugin | Gives you |
|---|---|
| **legion-router** | `legion-delegate` (scoped task → any model in an isolated git worktree → verified, metered diff), `legion-cursor`, `legion-claude`, routing + cost tables (`routing.toml`, `costs.json`), `legion-route`/`legion-optimize`. |
| **legion-observability** | `legion.span.v1` telemetry + `legion-trace`/`legion-report`/`legion-otel-export`, and the loops: `legion-doctor`, `legion-self-learn`, `legion-heal`, `legion-eval`, `legion-share`. |
| **legion-orchestrate** | Multi-model goal orchestration (fan-out → cross-verify → synthesize). |
| **legion-setup** | Cross-harness install + Codex/Cursor bridges. |
| **legion-codex-mode** | Codex-side wiring. |

## Using legion-core as a base

legion-core is meant to be the foundation under a domain agent (e.g. a trading agent, a research agent). You bring the domain; the core brings the orchestration:

1. **Consume it** — vendor this repo or install its marketplace, then layer your own plugins/skills/agents on top.
2. **Delegate work** — hand scoped tasks to `legion-delegate` / `legion-orchestrate`; you get verified, metered diffs back without wiring a model harness yourself.
3. **Stay healthy** — wire `legion-doctor` into CI (it already gates this repo), and opt into `legion-heal` (`LEGION_HEAL=1`) to auto-PR fixes for what the doctor finds.
4. **Tune routing** — point `legion-router/config/routing.toml` + `costs.json` at the models/archetypes your agent should prefer.

See [`docs/building-an-agent.md`](docs/building-an-agent.md) for the full recipe and [`docs/self-learning.md`](docs/self-learning.md) for the learn/heal loop.

## Install as a package

legion-core is published as a public npm package, so a downstream agent can pin a
versioned copy of the engine (bins + scripts + plugins) instead of cloning. This is
additive — the marketplace / source-clone paths still work.

```bash
# Add it to a project.
npm install @opus-aether-ai/legion-core            # or: bun add / pnpm add

# The engine CLIs are now on your project's bin path.
npx legion-doctor --help
npx legion-delegate run --archetype fix-bug --task "…" --repo .

# Or run a CLI without adding it to package.json.
npx --package @opus-aether-ai/legion-core legion-doctor --help
```

Package links:

- npmjs: <https://www.npmjs.com/package/@opus-aether-ai/legion-core>
- GitHub Packages mirror: <https://github.com/orgs/Opus-Aether-AI/packages/npm/package/legion-core>
- dist-tags: `npm view @opus-aether-ai/legion-core dist-tags`

Publishing is automated: [`release-please`](.github/workflows/release-please.yml)
cuts the release, then publishes to npmjs with Trusted Publishing / GitHub OIDC
and mirrors to GitHub Packages with `GITHUB_TOKEN`. Stable releases publish to
the npmjs `latest` dist-tag. The first package is live; before the next
automated publish, configure the npm Trusted Publisher for
`@opus-aether-ai/legion-core` at
<https://www.npmjs.com/package/@opus-aether-ai/legion-core/access> with
organization `Opus-Aether-AI`, repository `legion-core`, workflow filename
`release-please.yml`, environment `release`, and allowed action `npm publish`.
Each npm package supports one Trusted Publisher, so keep `release-please.yml` as
the canonical npmjs publisher.

## Configuration

Copy [`.env.example`](.env.example) → `.env`. Runtime prerequisites: `gh` + `jq` + `git`; `codex` and `cursor-agent` CLIs (authenticated) for those executors; `ANTHROPIC_API_KEY` for Claude routing.

## AFK intake lane

The GitHub intake edge lets humans or telemetry file an issue, then hand it to an AFK Legion worker by label. It is queue-based (`concurrency: agent-intake`), bounded, routed through Legion archetypes, and `implement` always opens a PR for human review; it never auto-merges.

```bash
# One-time label setup
gh label create 'agent:explore' --color 1d76db --description 'Run read-only AFK issue triage'
gh label create 'agent:implement' --color b60205 --description 'Run AFK implementation and open a PR'

# One-time secret setup
# Preferred generic secret. For the current Codex-backed delegate backend, this
# is the contents of ~/.codex/auth.json from a machine with `codex login status`.
gh secret set LEGION_INTAKE_AUTH_JSON < ~/.codex/auth.json

# Compatibility alias for existing installs; not needed if the generic secret is set.
# gh secret set CODEX_AUTH < ~/.codex/auth.json

# Fallback if using API-key login instead of auth JSON.
# gh secret set OPENAI_API_KEY --body "$OPENAI_API_KEY"

# Optional routing overrides. Usually leave these unset and use the defaults:
# explore -> second-opinion-review, implement -> implement-feature.
gh variable set LEGION_INTAKE_EXPLORE_ARCHETYPE --body final-review
gh variable set LEGION_INTAKE_IMPLEMENT_ARCHETYPE --body hard-bug
gh variable set LEGION_INTAKE_MODEL --body gpt-5.5
```

After that, adding `agent:explore` to an issue posts a short assessment comment, and adding `agent:implement` runs the same intake prompt in write mode and opens a PR whose body includes `Closes #N`. You can also run the thin `agent-intake-trigger` workflow manually with an issue number, mode, worker (`delegate`, `cursor`, or `custom`), optional `archetype` / `model` override, and optional `worker_bin` for a repo-local compatible runner. `legion-intake` also accepts `--worker` / `--worker-bin` / `LEGION_INTAKE_WORKER_BIN` for any runner that follows the Legion JSON result contract.

## Quality

`legion-doctor` + the `bats` suite gate every change (`.github/workflows/`). Run locally:

```bash
bats tests/                                   # unit + component suite
legion-observability/bin/legion-doctor        # install / schema / MCP / bridge health
```

## Security

Report suspected vulnerabilities privately; see [SECURITY.md](SECURITY.md).

## Credits

legion-core is original integration code, built in conversation with a broader
agent-harness ecosystem. See [CREDITS.md](CREDITS.md) for full attribution,
including svineet/harness-bench, autoresearch, auto-harness, MCP, Codex,
Claude Code, Cursor, and the local validation toolchain.

## License

[Apache-2.0](LICENSE). This is the reusable, model-agnostic Legion engine.
Enterprise support and pilots: see [ENTERPRISE.md](./ENTERPRISE.md).
