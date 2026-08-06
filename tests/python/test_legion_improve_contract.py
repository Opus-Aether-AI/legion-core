"""Public, black-box contract for the review-only improvement engine.

The engine is deliberately exercised only through ``legion-improve`` and its
durable JSON documents.  These tests are the acceptance contract for a future
implementation; they must not reach into private Python helpers.
"""

from concurrent.futures import ThreadPoolExecutor
import hashlib
import json
import os
import subprocess


ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
CLI = os.path.join(ROOT, "legion-observability", "bin", "legion-improve")
TRANSITIONS = (
    "eligible", "leased", "prepared", "candidate_ready", "evaluated",
    "reviewed", "draft_created",
)


def _git(*args, cwd):
    return subprocess.run(["git", *args], cwd=cwd, text=True, capture_output=True, check=True)


def _repo(tmp_path):
    repo = tmp_path / "operator-checkout"
    remote = tmp_path / "origin.git"
    repo.mkdir()
    _git("init", "-q", cwd=repo)
    _git("config", "user.email", "test@example.invalid", cwd=repo)
    _git("config", "user.name", "Test", cwd=repo)
    (repo / "allowed.md").write_text("before\n", encoding="utf-8")
    (repo / "outside.md").write_text("do not touch\n", encoding="utf-8")
    _git("add", ".", cwd=repo)
    _git("commit", "-qm", "initial", cwd=repo)
    _git("init", "--bare", "-q", str(remote), cwd=tmp_path)
    _git("remote", "add", "origin", str(remote), cwd=repo)
    _git("push", "-q", "-u", "origin", "HEAD:main", cwd=repo)
    return repo, remote


def _proposal(tmp_path, **overrides):
    proposal = {
        "schema": "legion.improvement-proposal.v1",
        "id": "proposal-safe-doc",
        "revision": 1,
        "maintainer_eligible": True,
        "kind": "documentation_guardrail",
        "summary": "Append one maintained guardrail.",
        "target": {"path": "allowed.md"},
        "candidate": {
            "operation": "append_markdown_guardrail",
            "content": "Validate the real workflow before declaring success.",
        },
        "validation": {"profile": "documentation"},
    }
    proposal.update(overrides)
    path = tmp_path / "proposal.json"
    path.write_text(json.dumps(proposal), encoding="utf-8")
    return path


def _run(repo, proposal, state, *args, env=None):
    command = ["bash", CLI, "run", "--repo", str(repo), "--proposal", str(proposal), "--state-dir", str(state), "--json", *args]
    result = subprocess.run(command, text=True, capture_output=True, env=env, check=False)
    assert result.stdout, result.stderr
    return result, json.loads(result.stdout)


def _inspect(state, fingerprint, env):
    result = subprocess.run(
        ["bash", CLI, "inspect", "--state-dir", str(state), "--fingerprint", fingerprint, "--json"],
        text=True, capture_output=True, env=env, check=False,
    )
    assert result.returncode == 0, result.stderr
    return json.loads(result.stdout)


def _queue(repo, queue_dir, state, *args, env=None):
    result = subprocess.run(
        [
            "bash", CLI, "queue", "--repo", str(repo), "--queue-dir", str(queue_dir),
            "--state-dir", str(state), "--json", *args,
        ],
        text=True, capture_output=True, env=env, check=False,
    )
    assert result.stdout, result.stderr
    return result, json.loads(result.stdout)


def _env(tmp_path):
    bin_dir = tmp_path / "bin"
    bin_dir.mkdir(parents=True)
    evaluator = bin_dir / "fixture-eval"
    evaluator.write_text(
        "#!/bin/sh\n"
        "mode=${FIXTURE_EVAL_MODE:-pass}\n"
        "candidate=false; grep -q 'Validate the real workflow' \"$1\" && candidate=true\n"
        "case \"$mode:$candidate\" in\n"
        "  noisy:*) awk 'BEGIN { for (i = 0; i < 200000; i++) printf \"x\" }'; exit 0 ;;\n"
        "  regression:true) exit 1 ;;\n"
        "  baseline-flake:false|candidate-flake:true)\n"
        "    count=0; [ -f \"$FIXTURE_EVAL_COUNTER\" ] && count=$(cat \"$FIXTURE_EVAL_COUNTER\")\n"
        "    count=$((count + 1)); printf '%s' \"$count\" > \"$FIXTURE_EVAL_COUNTER\"\n"
        "    [ $((count % 2)) -eq 0 ] ;;\n"
        "  *) exit 0 ;;\n"
        "esac\n",
        encoding="utf-8",
    )
    evaluator.chmod(0o755)
    reviewer = bin_dir / "legion-delegate"
    reviewer.write_text(
        "#!/bin/sh\n"
        "printf '%s\\n' \"$*\" >> \"$FIXTURE_REVIEW_LOG\"\n"
        "base= head=\n"
        "while [ $# -gt 0 ]; do\n"
        "  case \"$1\" in --base) base=$2; shift 2 ;; --head) head=$2; shift 2 ;; *) shift ;; esac\n"
        "done\n"
        "if [ \"${FIXTURE_REVIEW_MODE:-approve}\" = fail ]; then exit 23; fi\n"
        "verdict=approve\n"
        "[ \"${FIXTURE_REVIEW_MODE:-approve}\" = reject ] && verdict=request_changes\n"
        "printf '{\"status\":\"ok\",\"model\":\"independent-test-reviewer\",\"reviewed_base_sha\":\"%s\",\"reviewed_head_sha\":\"%s\",\"attempts\":1,\"verdict\":{\"verdict\":\"%s\",\"summary\":\"bounded\",\"findings\":[]}}\\n' \"$base\" \"$head\" \"$verdict\"\n",
        encoding="utf-8",
    )
    reviewer.chmod(0o755)
    gh = bin_dir / "gh"
    gh.write_text(
        "#!/bin/sh\nprintf '%s\\n' \"$*\" >> \"$FIXTURE_GH_LOG\"\n"
        "case \"$*\" in\n"
        "  *'pr create'*)\n"
        "    [ \"${FIXTURE_GH_MODE:-ok}\" = fail-create ] && exit 19\n"
        "    printf 'https://example.invalid/pr/7\\n' ;;\n"
        "esac\n",
        encoding="utf-8",
    )
    gh.chmod(0o755)
    env = os.environ.copy()
    env["PATH"] = str(bin_dir) + os.pathsep + env["PATH"]
    env["HOME"] = str(tmp_path / "home")
    env["FIXTURE_EVAL_COUNTER"] = str(tmp_path / "fixture-eval-count")
    env["FIXTURE_GH_LOG"] = str(tmp_path / "fixture-gh.log")
    env["FIXTURE_REVIEW_LOG"] = str(tmp_path / "fixture-review.log")
    env["LEGION_IMPROVE_VALIDATOR_BIN"] = str(evaluator)
    env["LEGION_IMPROVE_REVIEW_BIN"] = str(reviewer)
    return env


def _assert_private_and_bounded(value, repo):
    encoded = json.dumps(value, sort_keys=True)
    assert str(repo) not in encoded
    assert "fixture-only-secret" not in encoded
    assert len(encoded) <= 32_768


def test_public_schema_rejects_untyped_or_ineligible_proposals_before_leasing(tmp_path):
    repo, _ = _repo(tmp_path)
    state = tmp_path / "state"
    env = _env(tmp_path)
    for change in (
        {"schema": "untyped"},
        {"maintainer_eligible": False},
        {"target": {"path": "../escape"}},
        {
            "provenance": {
                "source": "learning-law",
                "source_id": "weak",
                "confidence": 0.99,
                "support": {"episodes": 20, "projects": 1},
                "evidence_ids": [],
            }
        },
    ):
        result, payload = _run(repo, _proposal(tmp_path, **change), state, "--mode", "dry-run", env=env)
        assert result.returncode != 0
        assert payload["state"] == "rejected"
        assert payload["reason"] in {"invalid_schema", "not_maintainer_eligible", "path_not_allowlisted"}
        assert not payload.get("lease_id")


def test_default_mode_is_off_and_has_no_side_effects(tmp_path):
    repo, _ = _repo(tmp_path)
    proposal = _proposal(tmp_path)
    state = tmp_path / "state"
    result, payload = _run(repo, proposal, state, env=_env(tmp_path))
    assert result.returncode == 0
    assert payload["mode"] == "off"
    assert payload["state"] == "eligible"
    assert not payload.get("branch")
    assert not payload.get("draft_pr")
    assert _git("status", "--porcelain", cwd=repo).stdout == ""


def test_public_allowlists_reject_unsafe_commands_paths_and_oversized_diffs(tmp_path):
    repo, _ = _repo(tmp_path)
    env = _env(tmp_path)
    cases = (
        ({"candidate": {"operation": "run_shell", "content": "touch outside.md"}}, "mutation_not_allowlisted"),
        ({"validation": {"profile": "run_anything"}}, "validation_not_allowlisted"),
        ({"limits": {"max_changed_lines": 0}}, "diff_too_large"),
    )
    for number, (change, reason) in enumerate(cases):
        result, payload = _run(repo, _proposal(tmp_path, **change), tmp_path / ("unsafe-" + str(number)), "--mode", "draft", env=env)
        assert result.returncode != 0
        assert payload["state"] == "rejected"
        assert payload["reason"] == reason
        assert (repo / "outside.md").read_text(encoding="utf-8") == "do not touch\n"


def test_unexpected_candidate_failure_is_a_durable_failed_terminal_state(tmp_path):
    repo, _ = _repo(tmp_path)
    proposal = _proposal(tmp_path, target={"path": "missing.md"})
    result, payload = _run(repo, proposal, tmp_path / "failed", "--mode", "draft", env=_env(tmp_path))
    assert result.returncode != 0
    assert payload["state"] == "failed"
    assert payload["reason"] == "candidate_target_unavailable"
    assert "draft_pr" not in payload


def test_noisy_validation_is_bounded_and_corrupt_resume_state_fails_closed(tmp_path):
    repo, _ = _repo(tmp_path)
    proposal = _proposal(tmp_path)
    noisy_env = _env(tmp_path / "noisy")
    noisy_env["FIXTURE_EVAL_MODE"] = "noisy"
    result, payload = _run(
        repo,
        proposal,
        tmp_path / "noisy-state",
        "--mode",
        "draft",
        env=noisy_env,
    )
    assert result.returncode != 0
    assert payload["state"] == "rejected"
    assert payload["reason"] == "baseline_failed"
    assert len(result.stdout) < 32_768

    state = tmp_path / "corrupt-state"
    env = _env(tmp_path / "corrupt")
    stopped, partial = _run(
        repo,
        proposal,
        state,
        "--mode",
        "draft",
        "--stop-after",
        "reviewed",
        env=env,
    )
    assert stopped.returncode != 0
    durable_path = state / "runs" / (partial["fingerprint"] + ".json")
    durable = json.loads(durable_path.read_text(encoding="utf-8"))
    durable.pop("review_receipt")
    durable_path.write_text(json.dumps(durable), encoding="utf-8")
    resumed, failed = _run(repo, proposal, state, "--mode", "draft", env=env)
    assert resumed.returncode != 0
    assert failed["state"] == "failed"
    assert failed["reason"] == "state_corrupt"
    assert not os.path.exists(env["FIXTURE_GH_LOG"])


def test_draft_lifecycle_is_durable_deterministic_isolated_and_review_only(tmp_path):
    repo, remote = _repo(tmp_path)
    proposal = _proposal(tmp_path)
    state = tmp_path / "state"
    env = _env(tmp_path)
    before_head = _git("rev-parse", "HEAD", cwd=repo).stdout.strip()
    before_status = _git("status", "--porcelain", cwd=repo).stdout

    result, payload = _run(repo, proposal, state, "--mode", "draft", env=env)
    assert result.returncode == 0, result.stderr
    assert payload["schema"] == "legion.improvement-run.v1"
    assert payload["state"] == "draft_created"
    assert payload["transitions"] == list(TRANSITIONS)
    assert payload["remote_identity"] == hashlib.sha256(str(remote).encode()).hexdigest()
    assert payload["base_sha"] == before_head
    assert payload["branch"] == "legion-improve/" + payload["fingerprint"]
    assert payload["draft_pr"]["draft"] is True
    assert payload["review_receipt"]["independent"] is True
    assert payload["review_receipt"]["reviewed_base_sha"] == before_head
    assert payload["review_receipt"]["reviewed_head_sha"] != before_head
    assert payload["review_receipt"]["reviewer"]["model"] == "independent-test-reviewer"
    assert payload["worktree"] != str(repo)
    assert os.path.commonpath([payload["worktree"], str(repo)]) != str(repo)
    assert _git("rev-parse", "HEAD", cwd=repo).stdout.strip() == before_head
    assert _git("status", "--porcelain", cwd=repo).stdout == before_status
    assert (repo / "allowed.md").read_text(encoding="utf-8") == "before\n"
    _assert_private_and_bounded(payload, repo)
    _assert_private_and_bounded(payload["draft_pr"]["body"], repo)
    gh_calls = open(env["FIXTURE_GH_LOG"], encoding="utf-8").read()
    assert "pr create" in gh_calls and "--draft" in gh_calls
    assert not any(
        line.startswith(("pr merge", "repo deploy", "workflow run"))
        for line in gh_calls.splitlines()
    )
    review_calls = open(env["FIXTURE_REVIEW_LOG"], encoding="utf-8").read()
    assert "review" in review_calls and "--base" in review_calls and "--head" in review_calls
    durable = _inspect(state, payload["fingerprint"], env)
    assert durable["state"] == "draft_created"
    assert durable["base_sha"] == before_head
    assert durable["draft_pr"]["id"] == payload["draft_pr"]["id"]
    durable_raw = json.loads(
        (state / "runs" / (payload["fingerprint"] + ".json")).read_text(encoding="utf-8")
    )
    _assert_private_and_bounded(durable_raw, repo)
    assert not (state / "worktrees" / payload["fingerprint"] / "candidate").exists()
    assert not (state / "worktrees" / payload["fingerprint"] / "baseline").exists()


def test_replay_and_atomic_leases_produce_one_fingerprint_branch_and_draft(tmp_path):
    repo, _ = _repo(tmp_path)
    proposal = _proposal(tmp_path)
    state = tmp_path / "state"
    env = _env(tmp_path)

    def invoke(_):
        result, payload = _run(repo, proposal, state, "--mode", "draft", env=env)
        assert result.returncode == 0, result.stderr
        return payload

    # Both the ordinary replay path and concurrent contenders are required to
    # converge on the same externally visible identity.
    sequential = [invoke(i) for i in range(100)]
    with ThreadPoolExecutor(max_workers=16) as pool:
        concurrent_results = list(pool.map(invoke, range(100)))
    identities = {(p["fingerprint"], p["branch"], p["draft_pr"]["id"]) for p in sequential + concurrent_results}
    assert len(identities) == 1
    assert {p["proposal_id"] for p in sequential + concurrent_results} == {"proposal-safe-doc"}


def test_independent_review_is_an_external_fail_closed_boundary(tmp_path):
    repo, _ = _repo(tmp_path)
    proposal = _proposal(tmp_path)
    reject_env = _env(tmp_path / "reject")
    reject_env["FIXTURE_REVIEW_MODE"] = "reject"
    result, payload = _run(
        repo, proposal, tmp_path / "review-reject", "--mode", "draft", env=reject_env
    )
    assert result.returncode != 0
    assert payload["state"] == "rejected"
    assert payload["reason"] == "review_requested_changes"
    assert "draft_pr" not in payload

    # Transport/service failure is fail-closed but retryable from the immutable
    # evaluated state; it must not require deleting state or rebuilding a diff.
    fail_env = _env(tmp_path / "fail")
    fail_env["FIXTURE_REVIEW_MODE"] = "fail"
    state = tmp_path / "review-fail"
    result, payload = _run(repo, proposal, state, "--mode", "draft", env=fail_env)
    assert result.returncode != 0
    assert payload["state"] == "evaluated"
    assert payload["reason"] == "independent_review_failed"
    assert "draft_pr" not in payload
    fail_env.pop("FIXTURE_REVIEW_MODE")
    resumed, done = _run(repo, proposal, state, "--mode", "draft", env=fail_env)
    assert resumed.returncode == 0, resumed.stderr
    assert done["state"] == "draft_created"


def test_queue_is_bounded_and_replays_terminal_proposals_without_republishing(tmp_path):
    repo, _ = _repo(tmp_path)
    queue_dir = tmp_path / "queue"
    queue_dir.mkdir()
    proposal = _proposal(queue_dir)
    state = tmp_path / "state"
    env = _env(tmp_path)

    first, first_payload = _queue(
        repo, queue_dir, state, "--mode", "draft", "--max", "1", env=env
    )
    assert first.returncode == 0, first.stderr
    assert first_payload["attempted"] == 1
    assert first_payload["results"][0]["state"] == "draft_created"
    second, second_payload = _queue(
        repo, queue_dir, state, "--mode", "draft", "--max", "1", env=env
    )
    assert second.returncode == 0, second.stderr
    assert second_payload["attempted"] == 0
    assert second_payload["skipped_terminal"] == 1
    assert second_payload["results"] == []
    assert not proposal.exists()
    assert open(env["FIXTURE_GH_LOG"], encoding="utf-8").read().count("pr create") == 1


def test_draft_api_failure_retries_from_reviewed_state_without_rereview(tmp_path):
    repo, _ = _repo(tmp_path)
    proposal = _proposal(tmp_path)
    state = tmp_path / "state"
    env = _env(tmp_path)
    env["FIXTURE_GH_MODE"] = "fail-create"

    failed, partial = _run(repo, proposal, state, "--mode", "draft", env=env)
    assert failed.returncode != 0
    assert partial["state"] == "reviewed"
    assert partial["reason"] == "draft_pr_create_failed"
    assert len(open(env["FIXTURE_REVIEW_LOG"], encoding="utf-8").read().splitlines()) == 1
    env.pop("FIXTURE_GH_MODE")
    resumed, done = _run(repo, proposal, state, "--mode", "draft", env=env)
    assert resumed.returncode == 0, resumed.stderr
    assert done["state"] == "draft_created"
    assert len(open(env["FIXTURE_REVIEW_LOG"], encoding="utf-8").read().splitlines()) == 1


def test_explicit_remote_base_does_not_move_a_release_detached_checkout(tmp_path):
    repo, _ = _repo(tmp_path)
    release_sha = _git("rev-parse", "HEAD", cwd=repo).stdout.strip()
    (repo / "outside.md").write_text("advanced main\n", encoding="utf-8")
    _git("add", ".", cwd=repo)
    _git("commit", "-qm", "advance main", cwd=repo)
    main_sha = _git("rev-parse", "HEAD", cwd=repo).stdout.strip()
    _git("push", "-q", "origin", "HEAD:main", cwd=repo)
    _git("checkout", "-q", "--detach", release_sha, cwd=repo)
    proposal = _proposal(tmp_path)

    result, payload = _run(
        repo,
        proposal,
        tmp_path / "state",
        "--base-ref",
        "main",
        "--mode",
        "draft",
        env=_env(tmp_path),
    )

    assert result.returncode == 0, result.stderr
    assert payload["base_source"] == "remote"
    assert payload["base_sha"] == main_sha
    assert _git("rev-parse", "HEAD", cwd=repo).stdout.strip() == release_sha
    assert _git("status", "--porcelain", cwd=repo).stdout == ""


def test_paired_repeats_reject_flakes_and_regressions_and_never_create_a_draft(tmp_path):
    repo, _ = _repo(tmp_path)
    proposal = _proposal(tmp_path)
    state = tmp_path / "state"
    env = _env(tmp_path)
    # These evaluator modes make the validation command alternate or make the
    # candidate worse while keeping the immutable baseline fixed.
    for mode, expected in (("baseline-flake", "baseline_variance"), ("candidate-flake", "candidate_variance"), ("regression", "regression")):
        trial = env.copy()
        trial["FIXTURE_EVAL_MODE"] = mode
        trial["FIXTURE_EVAL_COUNTER"] = str(tmp_path / (mode + "-count"))
        result, payload = _run(repo, proposal, state / mode, "--mode", "draft", "--evaluation-repeats", "2", env=trial)
        assert result.returncode != 0
        assert payload["state"] == "rejected"
        assert payload["reason"] == expected
        assert "draft_pr" not in payload


def test_resume_after_each_durable_transition_and_stale_remote_or_base_are_safe(tmp_path):
    repo, _ = _repo(tmp_path)
    proposal = _proposal(tmp_path)
    env = _env(tmp_path)
    for transition in TRANSITIONS[:-1]:
        state = tmp_path / ("resume-" + transition)
        crashed, partial = _run(repo, proposal, state, "--mode", "draft", "--stop-after", transition, env=env)
        assert crashed.returncode != 0
        assert partial["state"] == transition
        resumed, done = _run(repo, proposal, state, "--mode", "draft", env=env)
        assert resumed.returncode == 0, resumed.stderr
        assert done["state"] == "draft_created"
    state = tmp_path / "stale"
    stopped, _ = _run(repo, proposal, state, "--mode", "draft", "--stop-after", "prepared", env=env)
    assert stopped.returncode != 0
    (repo / "allowed.md").write_text("operator advanced base\n", encoding="utf-8")
    _git("add", ".", cwd=repo); _git("commit", "-qm", "advance", cwd=repo)
    result, payload = _run(repo, proposal, state, "--mode", "draft", env=env)
    assert result.returncode != 0
    assert payload["state"] == "stale"
    assert payload["reason"] in {"base_sha_changed", "remote_identity_changed"}

    # A remote replacement after the lease is equally stale, even when the
    # operator's checkout has not been modified by the engine.
    remote_race = tmp_path / "remote-race"
    remote_race.mkdir()
    fresh_repo, _ = _repo(remote_race)
    fresh_proposal = _proposal(remote_race)
    fresh_state = tmp_path / "remote-race-state"
    stopped, _ = _run(fresh_repo, fresh_proposal, fresh_state, "--mode", "draft", "--stop-after", "leased", env=env)
    assert stopped.returncode != 0
    _git("remote", "set-url", "origin", str(tmp_path / "replacement.git"), cwd=fresh_repo)
    result, payload = _run(fresh_repo, fresh_proposal, fresh_state, "--mode", "draft", env=env)
    assert result.returncode != 0
    assert payload["state"] == "stale"
    assert payload["reason"] == "remote_identity_changed"

    # Advancing the configured upstream from a second checkout invalidates the
    # lease even while the operator checkout itself remains at the frozen SHA.
    tip_race = tmp_path / "tip-race"
    tip_race.mkdir()
    tip_repo, tip_remote = _repo(tip_race)
    tip_proposal = _proposal(tip_race)
    tip_state = tmp_path / "tip-race-state"
    stopped, _ = _run(
        tip_repo, tip_proposal, tip_state, "--mode", "draft", "--stop-after", "leased", env=env
    )
    assert stopped.returncode != 0
    updater = tmp_path / "updater"
    _git("clone", "-q", "-b", "main", str(tip_remote), str(updater), cwd=tmp_path)
    _git("config", "user.email", "test@example.invalid", cwd=updater)
    _git("config", "user.name", "Test", cwd=updater)
    (updater / "remote.md").write_text("advanced remotely\n", encoding="utf-8")
    _git("add", ".", cwd=updater)
    _git("commit", "-qm", "remote advance", cwd=updater)
    _git("push", "-q", "origin", "HEAD:main", cwd=updater)
    result, payload = _run(tip_repo, tip_proposal, tip_state, "--mode", "draft", env=env)
    assert result.returncode != 0
    assert payload["state"] == "stale"
    assert payload["reason"] == "remote_base_sha_changed"
