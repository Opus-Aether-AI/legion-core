# Installer tests

bats-based tests for `scripts/install.sh`, `scripts/refresh.sh`, and `scripts/uninstall.sh`. Every test runs in total isolation — `$AGENTS_HOME`, `$HOME`, and `$PATH` are redirected to bats-managed temp dirs, and `claude` / `gh` / `crontab` are mocked. No test ever touches your real `~/.agents/`, `~/.codex/`, or system crontab.

## Run locally

```bash
# Install bats + kcov (one-time)
brew install bats-core kcov

# Run all tests (fast — no coverage)
bats tests/

# Run a single file
bats tests/install.bats

# Filter by test name
bats -f "cron" tests/

# With coverage (Linux only — kcov on macOS hits PTRACE limits)
mkdir coverage-output
kcov --include-path=scripts --exclude-pattern=/tests/ coverage-output bats tests/
open coverage-output/index.html
```

## Layout

```
tests/
├── README.md              ← this file
├── helpers/
│   └── setup.bash         ← shared setup_test_env, mocks helpers, assertions
├── mocks/
│   └── bin/               ← PATH-prepended fakes for claude, gh, crontab
├── fixtures/
│   ├── marketplace-minimal.json    ← 3-plugin synthetic marketplace
│   └── plugins/                    ← 3 plugin shapes (top-level / nested / Claude-only)
├── install.bats           ← 40 tests
├── refresh.bats           ← 5 tests
└── uninstall.bats         ← 16 tests
```

## Methodology

Tests exercise the scripts through their **public CLI interface only** — command-line args, exit codes, filesystem effects. No internal functions are called directly. A test that breaks during a refactor (without the user-observable behavior changing) is a sign the test was wrong, not the refactor.

Each test follows the same shape:

```bash
@test "description of the behavior" {
    # Arrange: optionally tweak state set up by setup()
    rm -rf "$AGENTS_HOME/.managed-by-legion-core"

    # Act: invoke the script via `run` so $status + $output are captured
    run bash "$INSTALL_SH" --refresh-symlinks

    # Assert: check exit code, filesystem state, mock call log
    [ "$status" -eq 0 ]
    [ "$(agents_skills_count)" = "3" ]
    assert_mock_called claude "marketplace add"
}
```

## Mocks

The three CLIs install.sh / uninstall.sh / refresh.sh depend on are fully mocked:

- **`tests/mocks/bin/claude`** — supports `plugin marketplace {list,add,remove,update}`, `plugin install`, `plugin uninstall`, `plugin list`. Marketplace state persists in `$HOME/.mock-claude-marketplaces` so it survives across subprocess invocations.
- **`tests/mocks/bin/gh`** — supports `auth status` (always "logged in"), `api repos/.../marketplace.json` (returns base64 of the fixture), `repo clone` (copies from `$MOCK_GH_CLONE_SOURCE` if set, else creates an empty `.git/`).
- **`tests/mocks/bin/crontab`** — reads/writes `$FAKE_CRONTAB_FILE` instead of the system crontab.

All mocks append their invocation to `$MOCK_CALL_LOG`, which tests assert against via `assert_mock_called` / `assert_mock_not_called`.

`git`, `jq`, and `bash` are NOT mocked — they operate on isolated temp dirs, so using the real binaries gives more realistic test coverage.

## Adding a test

1. Pick a behavior to verify. Phrase it as a sentence: "X happens when Y."
2. Add a `@test` block to the appropriate `.bats` file.
3. Use `setup_test_env` + `make_source_clone` from `helpers/setup.bash` for arrangement.
4. Use `run` to invoke the script; assert against `$status`, `$output`, filesystem state, and `$MOCK_CALL_LOG`.
5. Run locally: `bats tests/<file>.bats`. Then push — CI will run with kcov coverage.

If a behavior is hard to test through the public CLI, that's a hint the script has a too-narrow interface for that operation. Surface it as a flag rather than testing internals.

## Coverage gate

CI runs `kcov` against the bats suite and enforces **≥95% line coverage** on `scripts/*.sh`. Defensive `exit 1` paths after missing-tool checks (`jq`, `gh`, `git`) account for the 5% slack — these can't fire in CI because the tools are installed by the workflow. Tighten the threshold to 100% by adding explicit "tool missing" mocks.

PRs that drop coverage below threshold fail the `validate-installer-coverage` check and can't merge.
