<div align="center">
  <img src="identity/legion-banner.svg" alt="Legion Core — we are many; we move as one" width="720">
</div>

> **legion-core** — the model-agnostic orchestration engine behind Legion. The base layer you build your own agents on.

One will commands a host of agents — **GPT-5.x via Codex**, **Cursor**, **Claude** (and humans). legion-core gives you the parts that aren't domain-specific: scoped multi-model **delegation**, **telemetry**, a **health check**, **self-learning**, and **auto-healing** — so a new agent project starts from a working spine instead of a blank page.

```bash
gh api repos/Opus-Aether-AI/legion-core/contents/scripts/install.sh --jq '.content' | base64 -d | bash -s all
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

## Configuration

Copy [`.env.example`](.env.example) → `.env`. Runtime prerequisites: `gh` + `jq` + `git`; `codex` and `cursor-agent` CLIs (authenticated) for those executors; `ANTHROPIC_API_KEY` for Claude routing.

## Quality

`legion-doctor` + the `bats` suite gate every change (`.github/workflows/`). Run locally:

```bash
bats tests/                                   # unit + component suite
legion-observability/bin/legion-doctor        # install / schema / MCP / bridge health
```

## License

[Apache-2.0](LICENSE). Built from the private Legion marketplace; this core is the model-agnostic subset, intended to be reusable and (eventually) open.
