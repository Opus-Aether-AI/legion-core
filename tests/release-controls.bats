#!/usr/bin/env bats
# Release workflow policy and the shared required-workflow gate.

load 'helpers/setup'

setup() {
    setup_test_env
    unset GITHUB_WORKFLOW CHECK_TIMEOUT_SECONDS CHECK_POLL_INTERVAL_SECONDS MOCK_GH_API_FAIL
    export AWAIT_REQUIRED_WORKFLOWS="$REPO_ROOT/scripts/await-required-workflows.sh"
    export REPO="Opus-Aether-AI/legion-core"
    export SHA="0123456789012345678901234567890123456789"
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
    grep -q 'id-token: write' "$release"
    grep -q 'scripts/await-required-workflows.sh validate legion-ci' "$release"
    grep -q 'release_tag:' "$release"
    grep -q 'ref: refs/tags/${{ inputs.release_tag }}' "$release"
    grep -q 'git show-ref --tags --verify' "$release"
    grep -q 'tag_sha=' "$release"
    grep -q 'sha=${head_sha}' "$release"
    grep -q 'SHA: ${{ steps.recovery_ref.outputs.sha }}' "$release"
    grep -q 'package.json' "$release"
    grep -q 'marketplace.json' "$release"
    grep -q 'npm@12.0.2' "$release"
    grep -q 'GATED_SHA: ${{ github.sha }}' "$release"
    grep -qF 'head_sha="$(git rev-parse HEAD)"' "$release"
    grep -qF 'tag_sha="$(git rev-parse --verify "refs/tags/${RELEASE_TAG}^{commit}")"' "$release"
    grep -qF '[ "$head_sha" != "$GATED_SHA" ] || [ "$tag_sha" != "$GATED_SHA" ]' "$release"
    grep -q 'bash scripts/install.sh --validate-release-tag="$RELEASE_TAG"' "$release"
    grep -q -- '--clobber' "$release"
    grep -qF 'npm view "${PACKAGE_NAME}@${PACKAGE_VERSION}" version --registry=https://registry.npmjs.org' "$release"
    grep -qF 'npm view "${PACKAGE_NAME}@${PACKAGE_VERSION}" version --registry=https://npm.pkg.github.com' "$release"
    grep -q 'already exists on npmjs; skipping' "$release"
    grep -q 'already exists on GitHub Packages; skipping' "$release"
    grep -q 'gh workflow run validate.yml' "$release"
    grep -q 'gh workflow run legion-ci.yml' "$release"
    grep -q 'workflow_dispatch:' "$REPO_ROOT/.github/workflows/validate.yml"
    grep -q 'workflow_dispatch:' "$REPO_ROOT/.github/workflows/legion-ci.yml"

    local gate_line action_line automatic_asset_line automatic_publish_line
    local recovery_asset_line recovery_publish_line
    gate_line="$(grep -n 'needs: await-checks' "$release" | head -n1 | cut -d: -f1)"
    action_line="$(grep -n 'googleapis/release-please-action' "$release" | head -n1 | cut -d: -f1)"
    automatic_asset_line="$(grep -n 'gh release upload' "$release" | head -n1 | cut -d: -f1)"
    automatic_publish_line="$(grep -n 'npm publish --provenance' "$release" | head -n1 | cut -d: -f1)"
    recovery_asset_line="$(grep -n 'gh release upload' "$release" | tail -n1 | cut -d: -f1)"
    recovery_publish_line="$(grep -n 'npm publish --provenance' "$release" | tail -n1 | cut -d: -f1)"
    [ "$gate_line" -lt "$action_line" ]
    [ "$automatic_asset_line" -lt "$automatic_publish_line" ]
    [ "$recovery_asset_line" -lt "$recovery_publish_line" ]
}
