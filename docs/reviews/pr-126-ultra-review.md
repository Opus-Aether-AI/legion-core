# PR 126 ultra review

## Review target

- PR: `Opus-Aether-AI/legion-core#126`
- Base: `696cc3a6d6a3c321b430e83f69a6ef8d315266a5`
- Reviewed code head: `df46e59442407c25574125c36efd79de6cb98bf4`
- Review type: performance and simplification PR, immutable-SHA multi-agent review
- Confidence threshold: actionable findings at or above 80/100

The final review found no open findings at or above the confidence threshold.

## Shards and lenses

The review divided the changed surface into runtime/routing, learning and
observability, setup and bridge integrity, benchmarks and retention, and
regression evidence. Each shard was examined through correctness and
architecture, security and authority boundaries, performance and resource
bounds, testing and compatibility, and repository convention lenses.

The review also applied the simplify rule to distinguish duplicated work from
deliberate stage or classifier boundaries. Shared session discovery and JSONL
decoding were consolidated; distinct classifiers and frozen stage-specific
context compiles remain separate because they enforce different contracts.

## Findings closed during review

The review cycles identified and closed:

- legacy self-learning cursor bootstrap that could double-count or discard
  historical trace contrast, plus stale concurrent report application that
  could rewind cursors and aggregate state;
- benchmark retention that could prune an active corpus run, including the
  directory-creation race before its activity lease became visible;
- pre-resolved route state escaping its one-hop handoff and weakening a nested
  review sandbox;
- valid SSE `data:value` terminal events being treated as truncated streams;
- selected-profile Cursor generation removing the last known-good bridge
  before validating the marketplace and rendering replacements;
- malformed, missing, traversal, and symlink-escaped selected marketplace
  sources being interpreted as an empty profile instead of failing closed.

Independent remediation review confirmed each regression at 92 to 99
confidence and found no remaining actionable issue at or above 80/100.

## Validation

- Full Bats suite: 562 passed, including one explicitly skipped manual
  Sandcastle integration.
- Full Python suite: 394 passed.
- Focused self-learning and benchmark Python suites: 84 passed.
- Focused Cursor setup and bridge suite: 16 passed.
- Router daemon, fanout, cancellation, ShellCheck, Python compilation, Bun
  production build, JSON validation, version synchronization, and
  `git diff --check`: passed.
