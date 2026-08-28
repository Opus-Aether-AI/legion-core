---
name: legion-setup
kind: procedure
disable-model-invocation: true
description: Install or update the Legion model-agnostic execution-layer marketplace. Use when the user pastes the Legion GitHub repo link, says "install legion", "set up legion", "add legion", "update legion", "upgrade legion", or "refresh legion", or wants Legion on Claude, Codex, Cursor, opencode, DeepSeek, Pi, or Hermes. First run installs marketplace plugins, shared skills and CLIs, plus selected executor bridges; daily refresh is opt-in.
---

# Legion Setup — install & update in one skill

The whole team needs exactly two moves, both handled here.

## Install (first time)

If `legion-setup` is already on `$PATH` (Legion partly installed), just run it — it auto-detects and installs:

```bash
legion-setup install            # all plugins (default); or: minimal | <plugin-name>
```

If it's a brand-new machine (nothing installed yet), bootstrap with one paste — this installs the marketplace, plugins, shared skills for every supported harness, shared CLIs, and this skill (so updates are one word afterwards). Add `--cron` only when you want daily refresh/self-learning:

```bash
curl -fsSL https://raw.githubusercontent.com/Opus-Aether-AI/legion-core/main/scripts/install.sh | bash -s all
```

Requires `curl`, `jq`, `git`.

## Update (every time after)

Ask the active harness to **"update legion"**, or:

```bash
legion-setup update             # pulls latest + re-syncs everything
```

## Run Legion on Codex CLI

Legion is model-agnostic and runs natively on Codex CLI. Codex reads skills from
`~/.agents/skills`; routing remains role-driven, including any current
`legion-claude` fallback behavior configured by the runtime. One command wires
the marketplace into Codex:

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

## Run Legion on opencode

```bash
legion-setup opencode           # register MCPs + verify the shared CLI/skill wiring
legion-setup opencode mcp       # append marketplace MCPs to opencode's config
legion-setup opencode verify    # read-only readiness check
```

opencode reads the shared Legion skills from `~/.agents/skills`; restart it after
MCP registration.

## Run Legion on Pi or Hermes

Pi consumes its primary-mode guidance directly from the shared skill catalog.
Hermes does not scan that catalog by default, so setup creates one narrowly
managed `~/.hermes/skills/legion-hermes-mode` link to the shared source. It does
not rewrite `config.yaml` or replace operator-owned files:

```bash
legion-setup pi
legion-setup pi verify
legion-setup hermes
legion-setup hermes verify
```

The installer manages only Legion-owned symlinks in `~/.agents/skills` plus that
single Hermes discovery link; it never replaces a real user skill directory.
Use `legion-route --list-executors` to see all registered executors. DeepSeek
Harness needs a user-authored dsh profile before it can run; it ships no
headless preset.

## Make Legion the repository default

Use the idempotent repository initializer to add a precise Legion-first policy
without replacing existing agent instructions:

```bash
legion-init --repo .             # add/update managed blocks
legion-init --repo . --check     # CI: fail when blocks are missing or stale
legion-init --repo . --dry-run   # preview without writes
legion-init --repo . --remove    # remove only managed blocks
```

`legion-setup init` is an alias. The command resolves the Git root, serializes
mutations, and transactionally manages versioned blocks in `AGENTS.md` and
`CLAUDE.md`; `--check` and `--dry-run` do not write Git metadata. It preserves
every unmanaged byte and file mode, avoids duplicate `@AGENTS.md` imports, and
fails closed on malformed markers, case collisions, or symlinks. The policy
exports a clear role contract: primaries enter Legion; executors with
`LEGION_ACTIVE=1` implement their assigned slice without recursively delegating.

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
- User wants Legion **on opencode** ("legion on opencode", "opencode setup") → run `legion-setup opencode`, then `legion-setup opencode verify`.
- User wants Legion **on Pi** ("legion on pi", "pi setup") → run `legion-setup pi`, then `legion-setup pi verify`.
- User wants Legion **on Hermes** ("legion on hermes", "hermes setup") → run `legion-setup hermes`, then `legion-setup hermes verify`.
- `legion-setup` with no args auto-picks: update if installed, install if not. It's safe to re-run anytime.
