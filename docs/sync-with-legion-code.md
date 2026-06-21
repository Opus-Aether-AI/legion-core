# Keeping legion-core and legion-code in sync

legion-core is the **single source of truth** for the engine (the 5 `legion-*`
plugins). legion-code (the coding agent) and future agents (e.g. moneyball)
**consume** it; they don't edit the engine in place.

## Model: legion-code vendors legion-core

legion-code already vendors third-party plugins via `git-subdir` entries
(`scripts/vendor.sh` + `.github/workflows/sync-vendored.yml`). Vendor legion-core
the same way — its own engine becomes just another pinned upstream.

### One-time conversion (in legion-code)

For each of the 5 plugins, change its `marketplace.json` entry from an in-repo
source to a git-subdir source pointing at legion-core:

```jsonc
// before
{ "name": "legion-router", "source": "./legion-router", "version": "0.5.0" }
// after
{ "name": "legion-router", "version": "0.5.0",
  "source": { "source": "git-subdir",
              "url": "https://github.com/Opus-Aether-AI/legion-core.git",
              "path": "legion-router", "ref": "main", "sha": "<legion-core main sha>" } }
```

Then `scripts/vendor.sh` materialises them into `vendored/legion-*` and the
in-repo `legion-*` dirs are removed. Current legion-core main: `2d25d6f5a59c22e93f4734ca72121b5f6a2cfd84`.

### The one manual prerequisite

legion-core is **private**, so `sync-vendored.yml`'s weekly auto-refresh needs a
token with read access to it (the default `GITHUB_TOKEN` is scoped to one repo):

1. Create a fine-grained PAT (or GitHub App) with **contents: read** on
   `Opus-Aether-AI/legion-core`.
2. Add it to legion-code as the secret **`VENDOR_SYNC_TOKEN`** and pass it to the
   clone/ls-remote steps in `sync-vendored.yml`.

Until then, the vendored copy is still valid (it's committed); it just won't
auto-refresh.

## Alternative: push-mirror (core → code)

If you'd rather push than pull, a workflow in legion-core can open a PR to
legion-code on each release. Same token requirement (write access to legion-code).
Vendoring (pull) is recommended — it reuses machinery legion-code already has.
