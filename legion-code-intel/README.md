# legion-code-intel

Optional code-intelligence diagnostics for Legion.

`legion-code-intel` gives the orchestrator a stable artifact for static
diagnostic signals without making LSP servers a hard dependency of
`legion-core`. The first adapters use repo-native tools once per detected
project configuration:

- TypeScript: `tsc --noEmit --pretty false --project <config>`
- Python: `pyright --outputjson --project <config>`

Both are optional. If the target repo does not have a supported project marker
or the adapter binary is missing, the command reports `status=skipped` and exits
0.

## CLI

```bash
legion-code-intel diagnostics --repo . --adapter auto --json
legion-code-intel diagnostics --repo . --adapter typescript --changed-only --base HEAD --emit-span
```

Auto mode requires a TypeScript or Pyright configuration; selecting an adapter
explicitly retains loose-file fallback. `--timeout` is one total deadline per
adapter across all configured projects. At most 50 configured projects run by
default; use `--max-projects` to lower that fail-closed guard, or `0` for an
intentional unlimited audit.

Exit codes:

- `0`: no error diagnostics, or all optional adapters were skipped
- `1`: one or more error diagnostics were found
- `2`: adapter/runtime error

The JSON result uses `schema=legion.code-intel.v1` and can be stored as a build
artifact. With `--emit-span`, the command also writes a normal
`legion.span.v1` span to `$LEGION_TELEMETRY_DIR`, so benchmark and report tools
can measure diagnostic overhead.

## Why optional

Language servers require per-language installs, indexing, lifecycle management,
and repo-specific configuration. Keeping this plugin optional preserves
legion-core's lightweight routing/delegation/telemetry spine while giving
enterprise demos and benchmarks a real diagnostic gate to measure.
