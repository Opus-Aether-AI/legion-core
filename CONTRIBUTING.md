# Contributing to legion-core

Thanks for helping sharpen the engine. legion-core is the model-agnostic spine
that domain agents build on, so the bar is: stays generic, stays green.

## Ground rules

- **Keep it domain-free.** No trading/research/company-specific plugins, skills,
  or copy. Those belong in the agent repos that consume this core.
- **Green or it doesn't merge.** `legion-doctor` + `bats tests/` gate every PR.
- **Shell passes `shellcheck`.** Python passes its checks.
- **No secrets.** Credentials come from env or the OS keychain, never the tree.

## Workflow

1. Branch, make the change, add/extend tests.
2. Run locally:
   ```bash
   bats tests/
   legion-observability/bin/legion-doctor
   shellcheck $(git ls-files '*.sh')
   ```
3. Open a PR. CI runs the same gates.

## Known follow-ups (good first issues)

- `scripts/install.sh` still carries `opus`/`vendored` profile branches inherited
  from the parent marketplace; for the core, only `all` / `minimal` / `<name>` are
  meaningful. Simplify the profile menu.
- The Codex/Cursor MCP-bridge e2e tests assume a marketplace with MCP plugins
  (the core ships none); they're `skip`-guarded. Add fixture-based coverage so the
  bridge is exercised without real MCP plugins.
- Keychain usage (`security`) is macOS-only; add a Linux/secret-store path.

## Provenance

This core was extracted from the private Legion marketplace and sanitized of
org-specific references. See `docs/building-an-agent.md` for how to base a new
agent on it.
