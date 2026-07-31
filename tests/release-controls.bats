#!/usr/bin/env bats
# Release workflow policy and the shared required-workflow gate.

load 'helpers/setup'

setup() {
    setup_test_env
    unset GITHUB_WORKFLOW CHECK_TIMEOUT_SECONDS CHECK_POLL_INTERVAL_SECONDS
    export AWAIT_REQUIRED_WORKFLOWS="$REPO_ROOT/scripts/await-required-workflows.sh"
    export REPO="Opus-Aether-AI/legion-core"
    export SHA="0123456789012345678901234567890123456789"
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

@test "release workflows gate before tag creation and require a release tag for manual publishing" {
    local automatic="$REPO_ROOT/.github/workflows/release-please.yml"
    local manual="$REPO_ROOT/.github/workflows/publish-package.yml"

    grep -q 'needs: await-checks' "$automatic"
    grep -q 'scripts/await-required-workflows.sh validate legion-ci' "$automatic"
    grep -q 'scripts/await-required-workflows.sh validate legion-ci' "$manual"
    grep -q 'release_tag:' "$manual"
    grep -q 'ref: refs/tags/${{ inputs.release_tag }}' "$manual"
    grep -q 'git show-ref --tags --verify' "$manual"
    grep -q 'tag_sha=' "$manual"
    grep -q 'sha=${head_sha}' "$manual"
    grep -q 'SHA: ${{ steps.release_ref.outputs.sha }}' "$manual"
    grep -q 'package.json' "$manual"
    grep -q 'marketplace.json' "$manual"
    grep -q 'npm@12.0.2' "$automatic"
    grep -q 'npm@12.0.2' "$manual"
    ! grep -q -- '--clobber' "$automatic"
    grep -q 'gh workflow run validate.yml' "$automatic"
    grep -q 'gh workflow run legion-ci.yml' "$automatic"
    grep -q 'workflow_dispatch:' "$REPO_ROOT/.github/workflows/validate.yml"
    grep -q 'workflow_dispatch:' "$REPO_ROOT/.github/workflows/legion-ci.yml"

    local gate_line action_line
    gate_line="$(grep -n 'needs: await-checks' "$automatic" | head -n1 | cut -d: -f1)"
    action_line="$(grep -n 'googleapis/release-please-action' "$automatic" | head -n1 | cut -d: -f1)"
    [ "$gate_line" -lt "$action_line" ]
}
