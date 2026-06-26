# legion-router

Legion's multi-model brain. Lets Opus orchestrate and **delegate scoped sub-tasks to external model agents** (Codex / GPT-5.5 / GPT-5.4 / Cursor Agent), bringing back a **verified, metered diff** — plus an opt-in Anthropic-compatible metering proxy so all model spend lands in one place.

> One orchestrator, a legion of models.

## Tools

| Bin | Script | What it does |
|---|---|---|
| `legion-delegate` | `scripts/delegate.sh` | Delegate a task to a model agent via `codex exec` in an isolated git worktree; capture diff + last message + token usage; price it; emit a telemetry span; report usage to `/ingest`. Subcommands: `run`, `review`, `apply`, `cleanup`. |
| `legion-cursor` | `scripts/legion-cursor.sh` | Delegate a task to Cursor Agent headless (`agent -p`) in an isolated worktree; capture diff + result + usage; emit a telemetry span with `executor=cursor`. |
| `legion-intake` | `scripts/legion-intake.sh` | GitHub issue intake wrapper. Runs a compatible Legion worker (`delegate`, `cursor`, or `custom`) in explore or implement mode, comments assessment results, and opens review PRs for implementation diffs. |
| `legion-router` | `scripts/router.sh` | Manage the loopback `:8082` Anthropic-compatible metering proxy as a launchd service: `install`/`uninstall`/`start`/`stop`/`restart`/`status`/`logs`/`errors`/`dev`. Endpoints: `/health`, `/stats`, `POST /ingest`. Keys optional (runs as a pure meter). |

## Running the meter

```bash
legion-router install        # launchd service on 127.0.0.1:8082 (keys optional)
legion-router status         # health + which keys are set

# Opt a session/runner into metered Claude/MiniMax routing (never forced globally):
ANTHROPIC_BASE_URL=http://127.0.0.1:8082 claude ...

# GPT runs out-of-band via legion-delegate and POST to /ingest automatically.
curl -s http://127.0.0.1:8082/stats | jq '{totalCostUsd, byUpstream}'
```

The proxy binds **loopback only** — that is the sole auth on `/ingest`. Secrets resolve from direct env vars first, then from the best available local store at runtime: macOS Keychain via `security` on Darwin, `secret-tool`/libsecret on Linux when present, then 0600 files under `${XDG_CONFIG_HOME:-~/.config}/legion/router`. Per-model cost comes from `config/costs.json` (one source of truth, shared with `legion-delegate` and `legion-report`).

## Why a sidecar, not a proxy, for GPT

`codex exec` is an **autonomous agent** (task → edits), not a chat endpoint, and Codex authenticates via a ChatGPT subscription (no `OPENAI_API_KEY`). So GPT work can't sit on the proxy's HTTP hot path. Legion **splits transport from accounting**: Claude/MiniMax bytes flow *through* the proxy (translation-free); GPT runs *out-of-band* via `legion-delegate`, which POSTs a usage record *to* the proxy's `/ingest` sink. `legion-report` then shows GPT spend next to Claude.

## Quick start

```bash
# Delegate an edit to GPT-5.5; inspect the diff it returns, then apply
legion-delegate run --model gpt-5.5 --task "add a null-guard to bar() in src/foo.ts" --repo .
legion-delegate apply --run <RUN_ID> --repo .

# Delegate a scoped task to Cursor Agent headless
legion-cursor run --task "try the same fix with Cursor Agent; minimal edit" --repo .

# Cross-model second opinion on a branch
legion-delegate review --model gpt-5.5 --base main --repo .
```

Requires: `codex` CLI for `legion-delegate`, Cursor CLI (`agent` or `cursor-agent`) for `legion-cursor`, plus `jq` and `git`. The proxy additionally needs `bun`.

`legion-intake` is intentionally one level above the provider. By default it runs
`legion-delegate` (`gpt-5.4`), but `--worker cursor` or
`--worker custom --worker-bin ./path/to/runner` can swap in any runner that
accepts `run --sandbox ... --task ... --repo ...` and returns the standard
Legion JSON fields (`status`, `run_id`, `diff_path`, `last_message_path` or
`last_message`). Provider secrets are scrubbed from the worker environment
because GitHub issue text is untrusted; authenticate workers through local auth
files or their own safe store.

## Container/VM sandboxing (optional)

The zero-dependency default is still an isolated git worktree plus `codex exec`
with `read-only` or `workspace-write`. For real OS/VM isolation around an
explicit delegation, install Sandcastle in your working copy:

```bash
npm i -D @ai-hero/sandcastle
legion-delegate run --model gpt-5.5 --sandbox docker --task "..." --repo .
legion-delegate run --model gpt-5.5 --sandbox vercel --task "..." --repo .
```

`docker`, `podman`, and `vercel` are opt-in blast-radius protection only. If
Sandcastle is absent, those modes fail with an install hint instead of falling
back to the default worktree path.

## Sandbox lifecycle

`legion-delegate run` looks for optional lifecycle config in the target repo at
`.legion/sandbox.json`:

```json
{
  "install": "pnpm install",
  "dev": "pnpm dev",
  "copy": [".env.local", ".npmrc"]
}
```

All fields are optional. Setup runs after the isolated environment is created:

- `install`: runs inside the fresh worktree/sandbox. If omitted, Legion
  auto-detects a package install command from `bun.lockb`/`bun.lock`,
  `pnpm-lock.yaml`, `yarn.lock`, or `package-lock.json`. With no config and no
  supported lockfile, install is skipped.
- `copy`: trusted runs only. Each relative path is copied from the main repo
  root into the isolated environment at the same path. For attacker-controlled
  prompts, pass `--untrusted` or set `LEGION_UNTRUSTED=1`; credential copying is
  skipped and the rest of setup still runs. `legion-intake` always delegates
  GitHub issue bodies as untrusted.
- `dev`: opt-in. When set, Legion starts the command in the background inside
  the isolated environment, records its PID under the run artifacts, and stops it
  at run end even when `--keep` retains the worktree. Parallel worktrees can
  still clash if the dev command uses a fixed port.

For `--sandbox docker|podman|vercel`, install and dev setup run through
Sandcastle sandbox hooks, and trusted copy paths are passed through
Sandcastle's `copyToWorktree` option. Sandcastle owns deletion of the container
or VM when the run completes.

## Layout

```
legion-router/
├── bin/legion-delegate          # PATH shim
├── scripts/
│   ├── delegate.sh              # the delegation CLI
│   ├── sandcastle-run.mjs       # optional Sandcastle bridge for docker/podman/vercel
│   └── lib/
│       ├── codex-json.sh        # parse `codex exec --json` streams (single point of codex-schema knowledge)
│       └── cost.sh              # per-model USD cost from config/costs.json
├── config/costs.json            # per-model price table (GPT defaults to $0 — see SKILL.md)
├── references/                  # routing policy + cost model docs
└── SKILL.md                     # when/how Opus should delegate
```

## Safety

- `run` defaults to the `workspace-write` sandbox; `review` to `read-only`.
- `danger-full-access` is hard-blocked unless `LEGION_ALLOW_DANGER=1`.
- Task text is scanned for dangerous/injection patterns before write runs (`LEGION_ALLOW_UNSAFE=1` to override).
- Delegation never auto-applies a diff unless `--apply` is given and the diff applies cleanly.

## Telemetry

Each delegation writes a `legion.span.v1` JSONL span to `$LEGION_TELEMETRY_DIR` (default `~/.claude/logs/legion/spans/`). The `legion-observability` plugin aggregates these into per-executor cost/success/latency reports and OTLP traces.
