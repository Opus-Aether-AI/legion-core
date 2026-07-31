#!/usr/bin/env bats
# Release workflow policy and the shared required-workflow gate.

load 'helpers/setup'

setup() {
    setup_test_env
    unset GITHUB_WORKFLOW CHECK_TIMEOUT_SECONDS CHECK_POLL_INTERVAL_SECONDS MOCK_GH_API_FAIL
    export AWAIT_REQUIRED_WORKFLOWS="$REPO_ROOT/scripts/await-required-workflows.sh"
    export REPO="Opus-Aether-AI/legion-core"
    export SHA="0123456789012345678901234567890123456789"
    unset MOCK_RELEASE_EXISTS
}

make_pending_release_fixture() {
    local repo="$1"
    mkdir -p "$repo"
    printf '%s\n' '{"name":"@opus-aether-ai/legion-core","version":"0.19.0"}' > "$repo/package.json"
    printf '%s\n' '{".":"0.19.0"}' > "$repo/.release-please-manifest.json"
    (
        cd "$repo"
        git init --quiet --initial-branch=main 2>/dev/null || git init --quiet
        git -c user.email=test@test -c user.name=test add -A
        git -c user.email=test@test -c user.name=test commit -q -m "chore(main): release 0.19.0"
        git tag v0.19.0
    )
    printf '%s\n' '{"name":"@opus-aether-ai/legion-core","version":"0.19.1"}' > "$repo/package.json"
    printf '%s\n' '{".":"0.19.1"}' > "$repo/.release-please-manifest.json"
    (
        cd "$repo"
        git -c user.email=test@test -c user.name=test add -A
        git -c user.email=test@test -c user.name=test commit -q -m "chore(main): release 0.19.1"
    )
}

make_legacy_release_fixture() {
    local release_dir="$1"

    mkdir -p "$release_dir/.claude-plugin" "$release_dir/scripts"
    printf '%s\n' '{"name":"@opus-aether-ai/legion-core","version":"0.19.0"}' \
        > "$release_dir/package.json"
    printf '%s\n' '{"version":"0.19.0"}' \
        > "$release_dir/.claude-plugin/marketplace.json"
    cat > "$release_dir/scripts/install.sh" <<'EOF'
#!/usr/bin/env bash
if [[ " $* " == *" --validate-release-tag="* ]]; then
    echo "legacy installer does not support release-tag validation" >&2
    exit 64
fi
EOF
    chmod +x "$release_dir/scripts/install.sh"

    (
        cd "$release_dir"
        git init --quiet --initial-branch=main 2>/dev/null || git init --quiet
        git -c user.email=test@test -c user.name=test add -A
        git -c user.email=test@test -c user.name=test commit -q -m "legacy release"
        git tag v0.19.0
    )
}

@test "required workflow gate requires at least one workflow" {
    run bash "$AWAIT_REQUIRED_WORKFLOWS"
    [ "$status" -eq 2 ]
    [[ "$output" == *"at least one required workflow"* ]]
}

@test "required workflow gate rejects invalid timeout controls" {
    export CHECK_TIMEOUT_SECONDS=soon

    run bash "$AWAIT_REQUIRED_WORKFLOWS" validate
    [ "$status" -eq 2 ]
    [[ "$output" == *"must be non-negative integers"* ]]
}

@test "required workflow gate fails closed when GitHub cannot be read" {
    export MOCK_GH_API_FAIL=1

    run bash "$AWAIT_REQUIRED_WORKFLOWS" validate
    [ "$status" -eq 1 ]
    [[ "$output" == *"could not read workflow runs"* ]]
}

@test "required workflow gate polls before its deadline" {
    export CHECK_TIMEOUT_SECONDS=1
    export CHECK_POLL_INTERVAL_SECONDS=0
    export MOCK_REQUIRED_WORKFLOW_RUNS=$'validate\tin_progress\t-'

    run bash "$AWAIT_REQUIRED_WORKFLOWS" validate
    [ "$status" -eq 1 ]
    [[ "$output" == *"waiting for: validate(in_progress)"* ]]
    [[ "$output" == *"timed out waiting"* ]]
}

@test "required workflow gate accepts green validate and legion-ci push runs" {
    export MOCK_REQUIRED_WORKFLOW_RUNS=$'validate\tcompleted\tsuccess\nlegion-ci\tcompleted\tsuccess'

    run bash "$AWAIT_REQUIRED_WORKFLOWS" validate legion-ci
    [ "$status" -eq 0 ]
    [[ "$output" == *"all required checks green"* ]]
}

@test "required workflow gate fails closed when a required workflow is missing" {
    export CHECK_TIMEOUT_SECONDS=0
    export MOCK_REQUIRED_WORKFLOW_RUNS=$'validate\tcompleted\tsuccess'

    run bash "$AWAIT_REQUIRED_WORKFLOWS" validate legion-ci
    [ "$status" -eq 1 ]
    [[ "$output" == *"timed out waiting"* ]]
}

@test "required workflow gate fails closed when a required workflow is still pending at deadline" {
    export CHECK_TIMEOUT_SECONDS=0
    export MOCK_REQUIRED_WORKFLOW_RUNS=$'validate\tcompleted\tsuccess\nlegion-ci\tin_progress\t-'

    run bash "$AWAIT_REQUIRED_WORKFLOWS" validate legion-ci
    [ "$status" -eq 1 ]
    [[ "$output" == *"legion-ci(in_progress)"* ]]
}

@test "required workflow gate rejects skipped cancelled and failed conclusions" {
    local conclusion
    for conclusion in skipped cancelled failure; do
        export MOCK_REQUIRED_WORKFLOW_RUNS="$(printf 'validate\tcompleted\tsuccess\nlegion-ci\tcompleted\t%s' "$conclusion")"

        run bash "$AWAIT_REQUIRED_WORKFLOWS" validate legion-ci
        [ "$status" -eq 1 ]
        [[ "$output" == *"concluded '${conclusion}'"* ]]
    done
}

@test "required workflow gate refuses to wait on itself" {
    export GITHUB_WORKFLOW=validate

    run bash "$AWAIT_REQUIRED_WORKFLOWS" validate legion-ci
    [ "$status" -eq 2 ]
    [[ "$output" == *"refusing to wait on the current workflow"* ]]
}

@test "release workflow gates automatic publishing and keeps recovery on the trusted OIDC identity" {
    local release="$REPO_ROOT/.github/workflows/release-please.yml"
    local retired="$REPO_ROOT/.github/workflows/publish-package.yml"

    [ ! -e "$retired" ]
    grep -q 'needs: await-checks' "$release"
    grep -q 'workflow_dispatch:' "$release"
    grep -q 'recovery-publish:' "$release"
    grep -q 'GH_REPO: ${{ github.repository }}' "$release"
    grep -q 'id-token: write' "$release"
    grep -q 'scripts/await-required-workflows.sh validate legion-ci' "$release"
    grep -q 'release_tag:' "$release"
    grep -q 'ref: ${{ github.workflow_sha }}' "$release"
    grep -q 'path: control' "$release"
    grep -q 'ref: refs/tags/${{ inputs.release_tag }}' "$release"
    grep -q 'path: release' "$release"
    grep -q 'control/scripts/verify-release-recovery.sh' "$release"
    grep -q 'control/scripts/await-required-workflows.sh validate legion-ci' "$release"
    grep -q 'SHA: ${{ steps.recovery_ref.outputs.sha }}' "$release"
    grep -q 'package.json' "$release"
    grep -q 'marketplace.json' "$release"
    grep -q 'npm@12.0.2' "$release"
    grep -q 'GATED_SHA: ${{ needs.release-please.outputs.release_sha }}' "$release"
    grep -qF 'head_sha="$(git rev-parse HEAD)"' "$release"
    grep -qF 'tag_sha="$(git rev-parse --verify "refs/tags/${RELEASE_TAG}^{commit}")"' "$release"
    grep -qF '[ "$head_sha" != "$GATED_SHA" ] || [ "$tag_sha" != "$GATED_SHA" ]' "$release"
    grep -q 'bash scripts/install.sh --validate-release-tag="$RELEASE_TAG"' "$release"
    grep -q 'bash control/scripts/install.sh --validate-release-tag="$RELEASE_TAG"' "$release"
    grep -q 'release/scripts/install.sh --clobber' "$release"
    [ "$(grep -c 'working-directory: release' "$release")" -eq 2 ]
    grep -q -- '--clobber' "$release"
    grep -qF 'npm view "${PACKAGE_NAME}@${PACKAGE_VERSION}" version --registry=https://registry.npmjs.org' "$release"
    grep -qF 'npm view "${PACKAGE_NAME}@${PACKAGE_VERSION}" version --registry=https://npm.pkg.github.com' "$release"
    grep -q 'already exists on npmjs; skipping' "$release"
    grep -q 'already exists on GitHub Packages; skipping' "$release"
    grep -q 'gh workflow run validate.yml' "$release"
    grep -q 'gh workflow run legion-ci.yml' "$release"
    grep -q 'actions/create-github-app-token@bcd2ba49218906704ab6c1aa796996da409d3eb1' "$release"
    grep -q 'app-id: ${{ secrets.RELEASE_BOT_APP_ID }}' "$release"
    grep -q 'private-key: ${{ secrets.RELEASE_BOT_PRIVATE_KEY }}' "$release"
    grep -q 'permission-contents: write' "$release"
    grep -q 'scripts/prepare-pending-release.sh' "$release"
    grep -q 'SHA: ${{ steps.pending_release.outputs.release_sha }}' "$release"
    grep -q 'GH_TOKEN: ${{ steps.release_bot.outputs.token }}' "$release"
    grep -q '^  fleet-update:' "$release"
    local consumer
    for consumer in legion-code automaker-autoslicer moneyball nemesis legion-landing storefronts webapp moneyball-product factory-ops; do
        [ "$(grep -c "^            ${consumer}$" "$release")" -eq 2 ]
    done
    grep -q 'event_type: $event_type, client_payload:' "$release"
    grep -q 'workflow_dispatch:' "$REPO_ROOT/.github/workflows/validate.yml"
    grep -q 'workflow_dispatch:' "$REPO_ROOT/.github/workflows/legion-ci.yml"

    local gate_line action_line automatic_asset_line automatic_publish_line
    local recovery_job_line recovery_repo_line control_checkout_line validation_line release_checkout_line recovery_verify_line
    local recovery_gate_line recovery_asset_line recovery_publish_line
    gate_line="$(grep -n 'needs: await-checks' "$release" | head -n1 | cut -d: -f1)"
    action_line="$(grep -n 'googleapis/release-please-action' "$release" | head -n1 | cut -d: -f1)"
    automatic_asset_line="$(grep -n 'gh release upload' "$release" | head -n1 | cut -d: -f1)"
    automatic_publish_line="$(grep -n 'npm publish --provenance' "$release" | head -n1 | cut -d: -f1)"
    recovery_job_line="$(grep -n '^  recovery-publish:' "$release" | cut -d: -f1)"
    recovery_repo_line="$(grep -n 'GH_REPO: \${{ github.repository }}' "$release" | tail -n1 | cut -d: -f1)"
    control_checkout_line="$(grep -n 'ref: \${{ github.workflow_sha }}' "$release" | cut -d: -f1)"
    validation_line="$(grep -n 'bash control/scripts/install.sh --validate-release-tag' "$release" | cut -d: -f1)"
    release_checkout_line="$(grep -n 'ref: refs/tags/\${{ inputs.release_tag }}' "$release" | cut -d: -f1)"
    recovery_verify_line="$(grep -n 'control/scripts/verify-release-recovery.sh' "$release" | cut -d: -f1)"
    recovery_gate_line="$(grep -n 'control/scripts/await-required-workflows.sh' "$release" | cut -d: -f1)"
    recovery_asset_line="$(grep -n 'gh release upload' "$release" | tail -n1 | cut -d: -f1)"
    recovery_publish_line="$(grep -n 'npm publish --provenance' "$release" | tail -n1 | cut -d: -f1)"
    [ "$gate_line" -lt "$action_line" ]
    [ "$automatic_asset_line" -lt "$automatic_publish_line" ]
    [ "$recovery_job_line" -lt "$recovery_repo_line" ]
    [ "$recovery_repo_line" -lt "$recovery_asset_line" ]
    [ "$control_checkout_line" -lt "$validation_line" ]
    [ "$validation_line" -lt "$release_checkout_line" ]
    [ "$release_checkout_line" -lt "$recovery_verify_line" ]
    [ "$recovery_verify_line" -lt "$recovery_gate_line" ]
    [ "$recovery_gate_line" -lt "$recovery_asset_line" ]
    [ "$recovery_asset_line" -lt "$recovery_publish_line" ]
}

@test "pending release finder identifies the exact Release Please merge commit" {
    local repo="$TEST_TMPDIR/pending-release"
    local outputs="$TEST_TMPDIR/pending-release.outputs"
    make_pending_release_fixture "$repo"

    run env GITHUB_OUTPUT="$outputs" GH_REPO="$REPO" MOCK_RELEASE_EXISTS=0 \
        bash "$REPO_ROOT/scripts/prepare-pending-release.sh" "$repo"
    [ "$status" -eq 0 ]
    grep -q '^pending=true$' "$outputs"
    grep -q '^version=0.19.1$' "$outputs"
    grep -q '^tag_name=v0.19.1$' "$outputs"
    grep -q "^release_sha=$(git -C "$repo" rev-parse HEAD)$" "$outputs"
    grep -q '^tag_exists=false$' "$outputs"
}

@test "pending release finder is idempotent when the GitHub Release exists" {
    local repo="$TEST_TMPDIR/existing-release"
    local outputs="$TEST_TMPDIR/existing-release.outputs"
    make_pending_release_fixture "$repo"

    run env GITHUB_OUTPUT="$outputs" GH_REPO="$REPO" MOCK_RELEASE_EXISTS=1 \
        bash "$REPO_ROOT/scripts/prepare-pending-release.sh" "$repo"
    [ "$status" -eq 0 ]
    grep -q '^pending=false$' "$outputs"
    ! grep -q '^release_sha=' "$outputs"
}

@test "consumer update workflow pins immutable core identity and opens a validated PR" {
    local consumer="$REPO_ROOT/.github/workflows/legion-core-consumer-update.yml"

    grep -q 'workflow_call:' "$consumer"
    grep -q 'permission-contents' "$REPO_ROOT/.github/workflows/release-please.yml"
    grep -qF '"@opus-aether-ai/legion-core@$LEGION_CORE_VERSION"' "$consumer"
    grep -q 'legion-init --repo . --check' "$consumer"
    grep -q 'schema: "legion.core-pin.v1"' "$consumer"
    grep -q 'source_sha: $source_sha' "$consumer"
    grep -q 'bun_version:' "$consumer"
    grep -q 'python_version:' "$consumer"
    grep -q 'use_uv:' "$consumer"
    grep -q 'oven-sh/setup-bun@v2' "$consumer"
    grep -q 'astral-sh/setup-uv@v6' "$consumer"
    grep -q 'git push --force-with-lease=' "$consumer"
    grep -q 'gh pr create' "$consumer"
}

@test "recovery verifies a v0.19.0-style legacy tag with current controls" {
    local release_dir="$TEST_TMPDIR/legacy-v0.19.0"
    local outputs="$TEST_TMPDIR/recovery-outputs"

    make_legacy_release_fixture "$release_dir"

    run env GITHUB_OUTPUT="$outputs" \
        bash "$REPO_ROOT/scripts/verify-release-recovery.sh" v0.19.0 "$release_dir"
    [ "$status" -eq 0 ]
    grep -q '^package=@opus-aether-ai/legion-core$' "$outputs"
    grep -q '^version=0.19.0$' "$outputs"
    grep -Eq '^sha=[0-9a-f]{40}$' "$outputs"

    [ ! -e "$release_dir/scripts/await-required-workflows.sh" ]
    run bash "$release_dir/scripts/install.sh" --validate-release-tag=v0.19.0
    [ "$status" -eq 64 ]
}

@test "recovery verifier fails closed on untrusted or inconsistent release contents" {
    local release_dir="$TEST_TMPDIR/legacy-v0.19.0"
    local outputs="$TEST_TMPDIR/recovery-outputs"
    local verifier="$REPO_ROOT/scripts/verify-release-recovery.sh"

    make_legacy_release_fixture "$release_dir"

    run env GITHUB_OUTPUT="$outputs" bash "$verifier"
    [ "$status" -eq 2 ]
    [[ "$output" == *"usage:"* ]]

    run env GITHUB_OUTPUT="$outputs" bash "$verifier" v0.19.0 "$TEST_TMPDIR/not-a-checkout"
    [ "$status" -eq 2 ]
    [[ "$output" == *"is not a Git checkout"* ]]

    run env GITHUB_OUTPUT="$outputs" bash "$verifier" v0.19.1 "$release_dir"
    [ "$status" -eq 2 ]
    [[ "$output" == *"exact tag v0.19.1 is not present"* ]]

    printf 'newer commit\n' > "$release_dir/post-release.txt"
    git -C "$release_dir" -c user.email=test@test -c user.name=test add post-release.txt
    git -C "$release_dir" -c user.email=test@test -c user.name=test commit -q -m "post release"

    run env GITHUB_OUTPUT="$outputs" bash "$verifier" v0.19.0 "$release_dir"
    [ "$status" -eq 2 ]
    [[ "$output" == *"not checked-out"* ]]

    git -C "$release_dir" tag v0.19.1
    run env GITHUB_OUTPUT="$outputs" bash "$verifier" v0.19.1 "$release_dir"
    [ "$status" -eq 2 ]
    [[ "$output" == *"must match package.json (0.19.0) and marketplace.json (0.19.0)"* ]]
}
