# Building an agent on legion-core

[← back to README](../README.md)

legion-core is the spine; your agent is the body. The core never knows your
domain — it knows how to delegate work to models, measure it, and heal it. You
add the domain knowledge, surfaces, and policy on top.

## The split

| legion-core owns | your agent owns |
|---|---|
| Delegation (`legion-delegate`, `legion-cursor`, `legion-claude`) | Domain skills, agents, slash commands |
| Orchestration (`legion-orchestrate`) | The product surface (CLI, app, MCP) |
| Telemetry, doctor, self-learn, heal | Domain validators / evals |
| Routing + cost tables | Which models/archetypes your work prefers |
| Cross-harness install/bridges | Your brand + identity |

## Recipe

1. **Start a new repo** for your agent (e.g. `moneyball`).
2. **Depend on legion-core** — either:
   - *Vendor it* (recommended): pull legion-core into your marketplace the same
     way Legion vendors third-party plugins (a `git-subdir` entry in
     `.claude-plugin/marketplace.json`), so a weekly sync keeps the engine fresh; or
   - *Install its marketplace* alongside your own plugins.
3. **Add your domain plugins** next to the `legion-*` ones — your skills, agents,
   and commands. They get the cross-harness install + bridges for free.
4. **Delegate the hard parts** to `legion-delegate` / `legion-orchestrate` instead
   of wiring a model harness yourself. You receive a verified, metered diff.
5. **Gate on `legion-doctor`** in CI (copy `.github/workflows/legion-ci.yml`). Add
   your own checks via the same pattern; opt into `legion-heal` for auto-PR fixes.
6. **Point routing at your needs** — edit `legion-router/config/routing.toml` +
   `costs.json` so, say, bulk edits go to a cheap model and reviews to a strong one.

## What you get on day one

A new agent built this way starts with: multi-model delegation in isolated
worktrees, a metered telemetry stream, a CI health gate, a self-learning hint
loop, and optional auto-healing — none of which you had to build.

## Keeping in sync

If you vendor legion-core, bumps flow in as PRs you review (same model Legion
uses for its own vendored plugins). If you fork it, rebase periodically. Either
way, keep your domain code out of the `legion-*` directories so updates stay clean.
