# CLAUDE.md — legion-core

Contributor guidance for the **legion-core** engine (the model-agnostic subset
of the Legion marketplace).

## Scope

- This repo is the reusable orchestration core: 5 `legion-*` plugins, their
  schemas, config, install/bridge scripts, and the `bats` test suite.
- Domain agents (trading, research, etc.) build *on top* of this — they do not
  live here. Keep this repo free of domain-specific plugins, skills, or copy.

## Editing rules

1. Keep `.claude-plugin/marketplace.json` and each `<plugin>/.claude-plugin/plugin.json`
   version in sync; bump both on a plugin change.
2. Skill frontmatter stays strict: `name` + `description`, single-line description
   (no block scalars — `legion-doctor` enforces this).
3. Bash is the lingua franca; scripts must pass `shellcheck`.
4. Every change is gated by `legion-doctor` + `bats tests/` in CI.

## Verify locally

```bash
bats tests/
legion-observability/bin/legion-doctor
shellcheck $(git ls-files '*.sh')
```

## Conventions

- No secrets in the tree (gitleaks gates CI; creds live in env / Keychain).
- Telemetry conforms to `legion-observability/schema/legion.span.v1.schema.json`.
- New executors emit spans via `legion-trace emit` so the stream stays uniform.
