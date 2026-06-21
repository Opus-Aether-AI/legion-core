---
name: legion-setup
description: Install or update the Legion multi-model marketplace — one skill for both. Use when the user pastes the Legion GitHub repo link, says "install legion", "set up legion", "add legion", "update legion", "upgrade legion", "refresh legion", or wants Legion to work on/with Codex or Cursor. First run installs marketplace plugins, cross-harness skills, shared CLIs, daily refresh/self-learning, and the Codex/Cursor bridges. The `codex` and `cursor` subcommands wire marketplace MCPs, skills/agents, and delegation runners into those agents.
---

# Legion Setup — install & update in one skill

The whole team needs exactly two moves, both handled here.

## Install (first time)

If `legion-setup` is already on `$PATH` (Legion partly installed), just run it — it auto-detects and installs:

```bash
legion-setup install            # all plugins (default); or: opus | vendored | minimal
```

If it's a brand-new machine (nothing installed yet), bootstrap with one paste — this installs the marketplace, the plugins, cross-harness skills for Codex/Cursor/opencode, shared CLIs, a daily refresh/self-learning cron, **and this skill** (so updates are one word afterwards):

```bash
gh api repos/your-org/legion-core/contents/scripts/install.sh --jq '.content' | base64 -d | bash -s all
```

Requires `gh` authenticated (`gh auth login`), `jq`, `git`.

## Update (every time after)

Just ask Claude to **"update legion"**, or:

```bash
legion-setup update             # pulls latest + re-syncs everything
```

## Run Legion on Codex CLI

Legion is built for Claude Code but runs natively on Codex CLI too: both speak MCP,
both read skills from `~/.agents/skills`, and `legion-claude` lets a Codex-primary
session call Claude when it's worth it (with automatic GPT-5.5 fallback when your
Claude limit is hit). One command wires the marketplace into Codex:

```bash
legion-setup codex              # all: register MCPs + verify skill mirror + verify legion-claude
legion-setup codex mcp          # register every marketplace MCP into ~/.codex/config.toml (idempotent)
legion-setup codex skills --fix # mirror the cross-harness skills into ~/.codex/skills
legion-setup codex verify       # read-only readiness check (MCPs / skills / legion-claude / codex)
```

MCP registration is **append-only** — it never edits a server you (or a prior run)
already configured; pass `--force` to re-render. Restart `codex` afterwards to pick
up newly registered servers.

> **What does and doesn't carry over to Codex.** MCPs and skills work natively.
> Codex has **no** custom slash commands or subagents — those Legion surfaces are
> bridged as **skills** (which Codex does read), so the capability is preserved even
> though the invocation differs.

## Run Legion on Cursor Agent

Cursor has native MCP, AGENTS.md, headless `agent -p`, and user subagents. Legion wires those directly:

```bash
legion-setup cursor              # all: register MCPs + bridge commands/agents/skill-loader + verify
legion-setup cursor mcp          # append marketplace MCPs to ~/.cursor/mcp.json
legion-setup cursor agents       # write ~/.cursor/agents/legion-*.md bridge agents
legion-setup cursor verify       # read-only readiness check
```

Cursor invocation map:

- Use `legion-cursor run --task "..." --repo .` to delegate a scoped task to Cursor Agent headless and emit telemetry.
- Ask Cursor to use `legion-cmd-<name>` for Legion slash workflows such as feature/review-gate/ultra-review.
- Ask Cursor to use `legion-agent-<name>` for bridged Legion subagents.
- Ask Cursor to use `legion-skill-runner` when a task needs a mirrored skill from `~/.agents/skills`.

## Status / uninstall

```bash
legion-setup status             # what's installed + current version
legion-setup uninstall          # remove (add --all to also drop the marketplace + plugins)
```

## How to drive this as the assistant

- User pastes the repo link or says "install/set up legion" → run the **bootstrap one-paste** (covers a fresh machine), then confirm with `legion-setup status`.
- User says "update/upgrade/refresh legion" → run `legion-setup update` (idempotent; installs if somehow missing).
- User wants Legion **on Codex** ("legion on codex", "codex setup", "use legion in codex") → run `legion-setup codex`, then `legion-setup codex verify`.
- User wants Legion **on Cursor** ("legion on cursor", "cursor setup", "use legion in cursor") → run `legion-setup cursor`, then `legion-setup cursor verify`.
- `legion-setup` with no args auto-picks: update if installed, install if not. It's safe to re-run anytime.
