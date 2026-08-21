# legion-router

Legion's multi-model brain. Any supported primary harness can delegate scoped
work to configured executors and receive a reviewable, metered diff. An optional
Anthropic-compatible sidecar keeps proxied and out-of-band spend in one stream.

> One orchestrator, a legion of models.

## Tools

| Bin | Script | What it does |
|---|---|---|
| `legion-delegate` | `scripts/delegate.sh` | Delegate a task to a model agent via `codex exec` in an isolated git worktree; capture diff + last message + token usage; price it; emit a telemetry span; report usage to `/ingest`. Subcommands: `run`, `review`, `apply`, `cleanup`. |
| `legion-claude` | `scripts/legion-claude.sh` | Delegate to Claude headless in an isolated worktree, capture a patch, and optionally fall back through the configured Codex route. |
| `legion-cursor` | `scripts/legion-cursor.sh` | Delegate a task to Cursor Agent headless (`agent -p`) in an isolated worktree; capture diff + result + usage; emit a telemetry span with `executor=cursor`. |
| `legion-opencode` | `scripts/legion-opencode.sh` | Delegate to opencode headless in an isolated worktree and normalize its event stream into the Legion result/span contract. |
| `legion-pi` | `scripts/legion-pi.sh` | Delegate through Pi's official `-p --mode json --no-session` stream inside a filesystem write sandbox; validate the final settled `agent_end`, meter every `message_end` plus compaction call exactly once, and return a patch captured with parent-owned Git metadata. |
| `legion-hermes` | `scripts/legion-hermes.sh` | Delegate through Hermes `--oneshot` inside a filesystem write sandbox; parse its complete `--usage-file` JSON document while preserving stdout as opaque final text. |
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

`ANTHROPIC_BASE_URL` is client-facing only; the router never treats it as an
upstream. Advanced or test deployments can override upstream endpoints with
`LEGION_ANTHROPIC_UPSTREAM_URL` and `LEGION_MINIMAX_UPSTREAM_URL`. The router
fails fast if an override points back to its own loopback port.

The proxy binds **loopback only** — that is the sole auth on `/ingest`. Secrets resolve from direct env vars first, then from the best available local store at runtime: macOS Keychain via `security` on Darwin, `secret-tool`/libsecret on Linux when present, then 0600 files under `${XDG_CONFIG_HOME:-~/.config}/legion/router`. Per-model cost comes from `config/costs.json` (one source of truth, shared with `legion-delegate` and `legion-report`).

## Why a sidecar, not a proxy, for GPT

`codex exec` is an **autonomous agent** (task → edits), not a chat endpoint, and Codex authenticates via a ChatGPT subscription (no `OPENAI_API_KEY`). So GPT work can't sit on the proxy's HTTP hot path. Legion **splits transport from accounting**: Claude/MiniMax bytes flow *through* the proxy (translation-free); GPT runs *out-of-band* via `legion-delegate`, which POSTs a usage record *to* the proxy's `/ingest` sink. `legion-report` then shows GPT spend next to Claude.

## Quick start

```bash
# Delegate an edit through the configured Codex workhorse; inspect the diff, then apply
legion-delegate run --archetype implement-feature --task "add a null-guard to bar() in src/foo.ts" --repo .
legion-delegate apply --run <RUN_ID> --repo .

# Delegate a scoped task to Cursor Agent headless
legion-cursor run --task "try the same fix with Cursor Agent; minimal edit" --repo .

# Pi accepts an explicit model/thinking mapping (or --thinking high separately)
legion-pi run --model "$(legion-route --model-ref pi_default)" --thinking high --task "make the minimal fix" --repo .

# Hermes's documented one-shot runner writes a durable usage artifact
legion-hermes run --model "your-configured-hermes-model" --task "make the minimal fix" --repo .

# Structured Codex review of an immutable base/head pair, with optional bounded instructions
legion-delegate review --archetype security-review --base main --head HEAD --repo . \
  --task "Verify the selected security and learning guardrails."
```

Review output is schema-gated. The adapter accepts schema-valid JSON and
narrowly normalizes Codex's built-in `[P0]`–`[P3]` or explicit `No findings`
formats; any other prose remains an invalid, fail-closed verdict. `approve` and
`comment` cannot carry medium-or-higher findings.

Requires the CLI for each executor you use, plus `jq` and `git`. Pi and Hermes
children also require `sandbox-exec` (included with macOS) or Bubblewrap
(`bwrap`, install the `bubblewrap` package on Linux); their adapters fail closed
when neither boundary exists. The proxy additionally needs `bun`, and a
`python3` on `PATH` (or `LEGION_PYTHON`) because it reads the model catalog
through `legion-route.py` rather than parsing `models.toml` a second time. If no
interpreter resolves, the proxy still starts and warns, but every model role
falls through to its default.

## Tune routes from measured outcomes

Use `legion-report --by archetype` to inspect cost, success, latency, and the
share of delegated runs that carry a routing archetype. Then ask the advisory
optimizer for Pareto-safe candidates:

```bash
legion-report --by archetype
legion-optimize --json
```

The optimizer never edits `routing.toml`. Its `classification` summary reports
how many delegated runs were excluded from per-archetype proposals and how much
they cost, so explicit `--model` runs cannot silently bias or blind route tuning.

`legion-intake` is intentionally one level above the provider. By default it runs
`legion-delegate` (using the configured Codex route), but `--worker cursor` or
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
legion-delegate run --model "$(legion-route --model-ref codex_workhorse)" --sandbox docker --task "..." --repo .
legion-delegate run --model "$(legion-route --model-ref codex_workhorse)" --sandbox vercel --task "..." --repo .
```

`docker`, `podman`, and `vercel` are opt-in blast-radius protection only. If
Sandcastle is absent, those modes fail with an install hint instead of falling
back to the default worktree path.

Pi and Hermes provider processes run with the host filesystem read-only except
for their generated worktree, scrubbed private credential/temp/cache
directories, and the exact stdout, stderr, and provider-usage files opened by
Legion. This includes private Cursor config/data roots for a brokered Cursor
child. Container-daemon and other host control sockets are masked or denied,
their environment variables are removed, and installed `legion-delegate`
entrypoints are unavailable to the provider; only the single-use broker shim is
exposed. The private credential view is deleted after the run. Parent outputs
such as `diff.patch`, `last-message.txt`, and telemetry errors are never
provider-writable. A descendant-aware supervisor terminates children even when
they create a new session/process group, and brokered target output is bounded
while it is streamed. Linux runs also receive a private PID namespace. On
macOS, each provider and broker target receives a distinct, run-unique Seatbelt
deny/allow fingerprint; the supervisor drains every process that inherited that
policy after a quiet window, including rapid double-forks that shed ancestry,
environment, descriptors, and process groups, without selecting unrelated
sandboxes. macOS also blocks host process inspection/signalling. Pi's
`read-only` run also disables every writing tool (`--tools read,grep,find,ls`)
and rejects any resulting patch. Hermes runs with
`--ignore-user-config --toolsets terminal,file`
so repository rules remain available without auto-approved user plugins, hooks,
MCP servers, browser, or cron tools. Hermes does not expose an enforceable
read-only/no-tools one-shot mode, so `legion-hermes --sandbox read-only` fails
before launching Hermes; it never silently becomes a writable run. Neither
adapter accepts container or danger modes. Isolated diff capture preserves
allowlisted Git format and line-ending settings and fails closed when clean
filters (for example LFS) would require executing repository-configured code.

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
│       ├── cost.sh              # per-model USD cost from config/costs.json
│       └── executor-context.sh  # recursion-proof delegated-child role signal
├── config/costs.json            # per-model price table (GPT defaults to $0 — see SKILL.md)
├── references/                  # routing policy + cost model docs
└── SKILL.md                     # when/how a primary should delegate
```

## Safety

- `run` defaults to the `workspace-write` sandbox; `review` to `read-only`.
- `danger-full-access` is hard-blocked unless `LEGION_ALLOW_DANGER=1`.
- Task text is scanned for dangerous/injection patterns before runs and reviews (`LEGION_ALLOW_UNSAFE=1` to override).
- Delegation never auto-applies a diff unless `--apply` is given and the diff applies cleanly.
- Reviews resolve `--base`/`--head` once to commit SHAs, retry transient
  executor failures at most twice by default, and write a durable terminal receipt.
  Every Codex review attempt remains mechanically bound with `exec -s read-only
  review --base <resolved-sha>`; optional bounded, scanned task guidance is
  injected through Codex developer instructions and never replaces the base
  argument.
- Every executor receives `LEGION_ACTIVE=1`, `LEGION_EXECUTOR=1`,
  `LEGION_EXECUTOR_NAME`, `LEGION_DEPTH`, and `LEGION_RUN_ID`; initialized
  repository policy uses that context to prevent accidental recursive delegation.
  A worker can explicitly use `legion-delegate run --executor <different-harness>`
  for one cross-harness handoff (Claude, Codex, Cursor, opencode, Pi, or Hermes). The handoff
  retains task scanning, a fresh isolated worktree, parent trace linkage, and a
  default maximum depth of `2` (`LEGION_MAX_DEPTH`). Implicit, same-harness, and
  direct-adapter nested calls remain blocked. A sandboxed Pi or Hermes worker's
  command crosses an authenticated, single-use parent broker. The broker accepts
  only a typed subset of `run` (`--executor`, bounded task/stdin, sandbox,
  reasoning effort, integer token budget, and quiet); it rejects apply/keep,
  run IDs, internal flags, arbitrary repos/bases, and every unknown token. The
  target runs from a standalone disposable repository under an equivalent OS
  boundary: it cannot write source artifacts or the parent repository, and the
  source provider cannot write the target repository. Only validated child
  `legion.span.v1` records from a no-symlink, size-bounded source are appended
  to the canonical span store.

## Telemetry

Each delegation writes a `legion.span.v1` JSONL span to
`$LEGION_TELEMETRY_DIR`. The default is the current repository's
`~/.legion/projects/<repo-id>/spans/`; run `legion-state --repo .` to print the
resolved path. The `legion-observability` plugin aggregates these into
per-executor cost/success/latency reports and OTLP traces.
