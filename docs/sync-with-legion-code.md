# Keeping legion-core and legion-code in sync

`legion-core` owns the engine and its nine `legion-*` plugins. `legion-code`
owns the broader coding-agent marketplace. They are separate installed
dependencies: `legion-code` does not vendor or duplicate core plugin sources in
its marketplace.

## Install contract

The `legion-code` installer invokes the core installer, which maintains the core
checkout under `~/.agents/sources/legion-core`, shared skills, CLIs, and native
harness bridges. `legion-code` then installs its own marketplace and overlays.

Keep that order explicit:

1. install or update `legion-core`;
2. verify `legion-doctor --repo <target>`;
3. install or update `legion-code`;
4. verify the combined marketplace/context profile.

Do not copy core plugin directories into `legion-code`, add stale core plugin
counts to code docs, or hardcode model IDs there. Consumer guidance should name
Legion archetypes and model roles resolved through `legion-route`.

## Repository policy

Use the core-owned initializer in repositories that consume the combined stack:

```bash
legion-init --repo /path/to/repo
legion-init --repo /path/to/repo --check
```

It preserves existing instructions, manages only marked Legion blocks, makes
`AGENTS.md` the shared policy, and keeps `CLAUDE.md` as an importing
Claude-specific overlay. Consumer installers may expose an explicit
`--init-repo=<path>` flag, but must never rewrite the caller's current directory
implicitly.

## Refresh and ownership

Core refresh is opt-in (`--cron` or `LEGION_INSTALL_CRON=1`). An aggregate
`legion-code` refresh should run core refresh first and code refresh second in
one owned job so session learning and bridges stay coherent. Until that contract
is implemented in `legion-code`, update the two installations explicitly.

Uninstallers must also respect shared ownership: removing `legion-code` should
not remove a separately installed core unless the operator explicitly requests
engine removal.
