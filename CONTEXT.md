# CONTEXT.md — legion-core glossary

- `executor`: who performs a unit of work, such as `self`/Opus inline, `codex`, `cursor`, or an orchestrator process.
- `archetype`: the routing label in `legion-router/config/routing.toml` that binds a task shape to executor, model, sandbox, effort, and fallback.
- `delegation`: handing a scoped, stateless task to another executor with `legion-delegate`, `legion-cursor`, or `legion-claude`, then verifying the returned diff.
- `fanout`: parallel slice execution via `legion-fanout`; independent tasks run concurrently and `self` slices come back inline.
- `codex-share target`: a configurable routing preference in `routing.toml [targets].codex_share` (default `0.5`); override it with `LEGION_TARGET_CODEX_SHARE` or `--target`. It stays advisory unless an operator explicitly runs `legion-share gate`.
- `span (legion.span.v1)`: the JSONL telemetry record emitted for each work unit, carrying executor/model/status plus cost, timing, tokens, and trace linkage.
- `self-learn`: the daily loop that mines spans, reviews, failures, and manual records into harness memory, proposals, scorecards, and optional source experiments.
- `heal`: the opt-in auto-remediation flow that turns `legion-doctor` findings into isolated delegated fixes, re-gates them, and opens reviewable PRs.
- `doctor`: the static health check that validates marketplace metadata, frontmatter, bridges, schemas, Codex readiness, and router reachability.
- `worktree-isolation`: delegated and heal runs execute in separate git worktrees so diffs, branches, and cleanup stay isolated from the operator tree.
