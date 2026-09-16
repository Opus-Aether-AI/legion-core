# Primary-session convergence

Legion ends a primary harness turn from evidence, not from an arbitrary wall-clock
deadline or retry count. This applies equally when Claude, Codex, Cursor,
opencode, DeepSeek, Pi, or Hermes is primary.

At a material workflow boundary, write a `legion.convergence-checkpoint.v1`
document and run:

```bash
legion-converge --checkpoint checkpoint.json --repo . --json
```

The source fingerprint should identify the exact tree, artifact set, or other
input being validated. Each required check carries its own evidence fingerprint.
Every terminal review—clean or blocking—must identify its full immutable commit
SHA and repeat the exact source fingerprint it reviewed. Missing or mismatched
review evidence fails closed.

```json
{
  "schema": "legion.convergence-checkpoint.v1",
  "task_id": "fix-session-convergence",
  "source_fingerprint": "git-tree-or-artifact-digest",
  "checks": [
    {
      "id": "tests",
      "scope": "local",
      "status": "passed",
      "evidence_fingerprint": "test-result-digest"
    },
    {
      "id": "ci/installer",
      "scope": "external",
      "status": "pending",
      "evidence_fingerprint": "check-run-id-and-status"
    }
  ],
  "review": {
    "head_sha": "0123456789abcdef0123456789abcdef01234567",
    "source_fingerprint": "git-tree-or-artifact-digest",
    "blocking_findings": [],
    "suggestions": [{"fingerprint": "optional-rename"}]
  }
}
```

| State | Meaning | Primary action |
|---|---|---|
| `actionable` | A required local check failed or is pending, a blocking review finding exists, or its evidence changed. | Continue from the new evidence. |
| `complete` | Required evidence passed and no blocking review finding remains. | Yield the turn. Non-blocking suggestions do not reopen it. |
| `waiting_external` | Only external checks are pending. | Yield instead of polling. Resume when external state changes. |
| `blocked` | The same source and actionable evidence were already attempted. | Yield and report no progress. |

The checkpoint journal lives under the repository's resolved Legion state root.
Task IDs, check IDs, source fingerprints, and evidence are stored only as
SHA-256 digests; the journal directory is mode `0700` and its JSONL files are
mode `0600`.
Checkpoint decisions are serialized per task so concurrent primary processes
cannot both mistake the same evidence for new progress. Separate privacy-safe
attempt markers remember every source/failure pair, so an A → B → A oscillation
still blocks instead of keeping the turn alive.

`--no-record` performs a stateless classification for diagnostics. It cannot
detect repeated evidence and should not drive a real primary workflow.
