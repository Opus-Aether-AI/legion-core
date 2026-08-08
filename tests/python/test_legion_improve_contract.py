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
IMPROVEMENT_PR_BODY = (
    "Review-only Legion improvement. The exact remote base and candidate "
    "passed repeated paired gates plus an independent immutable review. "
    "Human review is required; this automation cannot merge or deploy."
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
        "provenance": {
            "source": "learning-law",
            "source_id": "law-source-id",
            "law_key": "verify-before-declaring-done",
            "confidence": 0.95,
            "support": {"episodes": 6, "projects": 4},
            "evidence_ids": ["evidence-1"],
        },
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
        # Findings are independent of the verdict on purpose: a reviewer that
        # says "approve" while reporting a blocking finding is the shape the
        # publish gate has to catch.
        "findings='[]'\n"
        "if [ -n \"${FIXTURE_REVIEW_FINDING_SEVERITY:-}\" ]; then\n"
        "  findings=$(printf '[{\"severity\":\"%s\",\"title\":\"fixture finding\",\"detail\":\"bounded\"}]' \"$FIXTURE_REVIEW_FINDING_SEVERITY\")\n"
        "fi\n"
        "printf '{\"status\":\"ok\",\"model\":\"independent-test-reviewer\",\"reviewed_base_sha\":\"%s\",\"reviewed_head_sha\":\"%s\",\"attempts\":1,\"verdict\":{\"verdict\":\"%s\",\"summary\":\"bounded\",\"findings\":%s}}\\n' \"$base\" \"$head\" \"$verdict\" \"$findings\"\n",
        encoding="utf-8",
    )
    reviewer.chmod(0o755)
    gh = bin_dir / "gh"
    gh.write_text(
        "#!/bin/sh\nprintf '%s\\n' \"$*\" >> \"$FIXTURE_GH_LOG\"\n"
        "case \"$*\" in\n"
        "  *'pr list'*)\n"
        "    case \"${FIXTURE_GH_MODE:-ok}\" in\n"
        "      existing-good)\n"
        "        head=; previous=\n"
        "        for arg in \"$@\"; do [ \"$previous\" = --head ] && head=$arg; previous=$arg; done\n"
        "        oid=$(git rev-parse \"$head\"); base_oid=$(git rev-parse refs/remotes/origin/main)\n"
        "        printf '[{\"number\":7,\"url\":\"https://github.com/fixture/repo/pull/7\",\"state\":\"OPEN\",\"isDraft\":true,\"body\":\"%s\",\"baseRefName\":\"main\",\"baseRefOid\":\"%s\",\"headRefName\":\"%s\",\"headRefOid\":\"%s\"}]\\n' \"$FIXTURE_PR_BODY\" \"$base_oid\" \"$head\" \"$oid\" ;;\n"
        "      existing-closed|existing-merged)\n"
        "        head=; previous=\n"
        "        for arg in \"$@\"; do [ \"$previous\" = --head ] && head=$arg; previous=$arg; done\n"
        "        oid=$(git rev-parse \"$head\"); base_oid=$(git rev-parse refs/remotes/origin/main)\n"
        "        state=CLOSED; draft=true\n"
        "        [ \"$FIXTURE_GH_MODE\" = existing-merged ] && state=MERGED && draft=false\n"
        "        printf '[{\"number\":7,\"url\":\"https://github.com/fixture/repo/pull/7\",\"state\":\"%s\",\"isDraft\":%s,\"body\":\"%s\",\"baseRefName\":\"main\",\"baseRefOid\":\"%s\",\"headRefName\":\"%s\",\"headRefOid\":\"%s\"}]\\n' \"$state\" \"$draft\" \"$FIXTURE_PR_BODY\" \"$base_oid\" \"$head\" \"$oid\" ;;\n"
        "      existing-body-wrong)\n"
        "        head=; previous=\n"
        "        for arg in \"$@\"; do [ \"$previous\" = --head ] && head=$arg; previous=$arg; done\n"
        "        oid=$(git rev-parse \"$head\"); base_oid=$(git rev-parse refs/remotes/origin/main)\n"
        "        printf '[{\"number\":7,\"url\":\"https://github.com/fixture/repo/pull/7\",\"state\":\"OPEN\",\"isDraft\":true,\"body\":\"tampered\",\"baseRefName\":\"main\",\"baseRefOid\":\"%s\",\"headRefName\":\"%s\",\"headRefOid\":\"%s\"}]\\n' \"$base_oid\" \"$head\" \"$oid\" ;;\n"
        "      existing-wrong)\n"
        "        printf '[{\"number\":8,\"url\":\"https://github.com/fixture/repo/pull/8\",\"state\":\"OPEN\",\"isDraft\":true,\"baseRefName\":\"wrong\",\"baseRefOid\":\"0000000000000000000000000000000000000000\",\"headRefName\":\"wrong\",\"headRefOid\":\"0000000000000000000000000000000000000000\"}]\\n' ;;\n"
        "      fail-list) exit 18 ;;\n"
        "      *) printf '[]\\n' ;;\n"
        "    esac ;;\n"
        "  *'pr create'*)\n"
        "    [ \"${FIXTURE_GH_MODE:-ok}\" = fail-create ] && exit 19\n"
        "    if [ \"${FIXTURE_GH_MODE:-ok}\" = race-base ] || [ \"${FIXTURE_GH_MODE:-ok}\" = race-base-close-once ]; then\n"
        "      base=$(git rev-parse refs/remotes/origin/main); tree=$(git rev-parse \"$base^{tree}\")\n"
        "      next=$(printf 'race base\\n' | git commit-tree \"$tree\" -p \"$base\")\n"
        "      git push -q origin \"$next:refs/heads/main\"\n"
        "    fi\n"
        "    printf 'https://github.com/fixture/repo/pull/7\\n' ;;\n"
        "  *'pr close'*)\n"
        "    if [ \"${FIXTURE_GH_MODE:-ok}\" = race-base-close-once ]; then\n"
        "      count=0; [ -f \"$FIXTURE_GH_CLOSE_COUNTER\" ] && count=$(cat \"$FIXTURE_GH_CLOSE_COUNTER\")\n"
        "      count=$((count + 1)); printf '%s' \"$count\" > \"$FIXTURE_GH_CLOSE_COUNTER\"\n"
        "      [ \"$count\" -eq 1 ] && exit 21\n"
        "    fi; true ;;\n"
        "  *'pr view'*)\n"
        "    [ \"${FIXTURE_GH_MODE:-ok}\" = fail-view ] && exit 20\n"
        "    head=$(git for-each-ref --format='%(refname:short)' 'refs/heads/legion-improve/*' | head -n 1)\n"
        "    oid=$(git rev-parse \"$head\"); base_oid=$(git rev-parse refs/remotes/origin/main)\n"
        "    printf '{\"number\":7,\"url\":\"https://github.com/fixture/repo/pull/7\",\"state\":\"OPEN\",\"isDraft\":true,\"body\":\"%s\",\"baseRefName\":\"main\",\"baseRefOid\":\"%s\",\"headRefName\":\"%s\",\"headRefOid\":\"%s\"}\\n' \"$FIXTURE_PR_BODY\" \"$base_oid\" \"$head\" \"$oid\" ;;\n"
        "esac\n",
        encoding="utf-8",
    )
    gh.chmod(0o755)
    env = os.environ.copy()
    env["PATH"] = str(bin_dir) + os.pathsep + env["PATH"]
    env["HOME"] = str(tmp_path / "home")
    env["FIXTURE_EVAL_COUNTER"] = str(tmp_path / "fixture-eval-count")
    env["FIXTURE_GH_LOG"] = str(tmp_path / "fixture-gh.log")
    env["FIXTURE_GH_CLOSE_COUNTER"] = str(tmp_path / "fixture-gh-close-count")
    env["FIXTURE_REVIEW_LOG"] = str(tmp_path / "fixture-review.log")
    env["FIXTURE_PR_BODY"] = IMPROVEMENT_PR_BODY
    env["LEGION_IMPROVE_VALIDATOR_BIN"] = str(evaluator)
    env["LEGION_IMPROVE_REVIEW_BIN"] = str(reviewer)
    env["LEGION_IMPROVE_GITHUB_REPOSITORY"] = "fixture/repo"
    return env


def _reviewed_state(repo, proposal, state, env):
    """Drive one proposal to the durable reviewed state and return its record."""
    stopped, payload = _run(
        repo, proposal, state, "--mode", "draft", "--stop-after", "reviewed", env=env
    )
    assert stopped.returncode != 0
    assert payload["state"] == "reviewed"
    path = state / "runs" / (payload["fingerprint"] + ".json")
    return payload, path, json.loads(path.read_text(encoding="utf-8"))


def _reseal_review_receipt(receipt):
    """Recompute the engine's tamper-evident receipt id after editing a record.

    Durable records are rejected outright when the id no longer matches, so a
    test that wants the *publish-time* recheck to be the failing gate has to
    hand the engine a record that is otherwise perfectly well formed.
    """
    body = {key: value for key, value in receipt.items() if key != "id"}
    canonical = json.dumps(body, sort_keys=True, separators=(",", ":"), ensure_ascii=True)
    receipt["id"] = hashlib.sha256(canonical.encode("utf-8")).hexdigest()[:24]
    return receipt


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
        {"revision": True},
        {"limits": {"max_changed_lines": True}},
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


def test_eligibility_bar_cannot_be_skipped_by_omitting_provenance(tmp_path):
    """The engine, not the proposal author, enforces the evidence bar.

    The documented bar is an active cross-project law with confidence >= 0.9,
    >= 5 supporting episodes across >= 3 projects. It used to sit behind an
    `if provenance is not None` guard, so a proposal that simply left the key
    out skipped the check entirely while remaining schema valid.
    """
    repo, _ = _repo(tmp_path)
    state = tmp_path / "state"
    env = _env(tmp_path)
    ineligible = (
        # No provenance at all: previously accepted.
        {"provenance": None},
        # Provenance from an unrecognized evidence class.
        {
            "provenance": {
                "source": "manual",
                "source_id": "hand-written",
                "law_key": "hand-written-law",
                "confidence": 1.0,
                "support": {"episodes": 99, "projects": 99},
                "evidence_ids": ["e1"],
            }
        },
        # A real law that has not cleared the confidence bar.
        {
            "provenance": {
                "source": "learning-law",
                "source_id": "weak-confidence",
                "law_key": "weak-law",
                "confidence": 0.5,
                "support": {"episodes": 9, "projects": 9},
                "evidence_ids": ["e1"],
            }
        },
    )
    for change in ineligible:
        proposal = _proposal(tmp_path, **change)
        if change["provenance"] is None:
            payload_text = json.loads(proposal.read_text(encoding="utf-8"))
            payload_text.pop("provenance", None)
            proposal.write_text(json.dumps(payload_text), encoding="utf-8")

        result, payload = _run(repo, proposal, state, "--mode", "dry-run", env=env)

        assert result.returncode != 0, change
        assert payload["state"] == "rejected", change
        assert payload["reason"] in {"invalid_schema", "not_maintainer_eligible"}, change
        assert not payload.get("lease_id"), change


def test_corrupt_resume_state_fails_closed_instead_of_crashing(tmp_path):
    """Unreadable durable state must not abort the process with a traceback.

    read_json is the entry point for state that may have been truncated or
    hand-edited. A deeply nested document raises RecursionError, which is not
    an OSError or ValueError, so it used to escape and kill the run before the
    corrupt-state path could report a structured result.
    """
    import importlib.util

    module_path = os.path.join(
        ROOT, "legion-observability", "scripts", "legion-improve.py"
    )
    spec = importlib.util.spec_from_file_location("legion_improve", module_path)
    improve = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(improve)

    deep = tmp_path / "deep.json"
    deep.write_text("[" * 200_000 + "]" * 200_000, encoding="utf-8")
    assert improve.read_json(deep) is None

    truncated = tmp_path / "truncated.json"
    truncated.write_text('{"state": "reviewed"', encoding="utf-8")
    assert improve.read_json(truncated) is None

    not_an_object = tmp_path / "list.json"
    not_an_object.write_text("[1, 2, 3]", encoding="utf-8")
    assert improve.read_json(not_an_object) is None


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

    queue_dir = tmp_path / "off-queue"
    queue_dir.mkdir()
    invalid = queue_dir / "invalid.json"
    invalid.write_text("{not-json", encoding="utf-8")
    queued, queue_payload = _queue(
        repo, queue_dir, tmp_path / "off-state", env=_env(tmp_path / "off")
    )
    assert queued.returncode == 0
    assert queue_payload["mode"] == "off"
    assert queue_payload["attempted"] == 0
    assert invalid.is_file()
    assert not (queue_dir / "quarantine").exists()


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


def test_written_candidate_paths_are_reallowlisted_after_the_mutation(tmp_path):
    """Schema validation is a filter, not the allowlist.

    ``path_not_allowlisted`` is checked twice: once against the declared target
    before anything is built, and again against what Git actually reports the
    candidate changed. The other tests only ever reach the first check, which
    leaves the second -- the one that observes the real mutation rather than
    the claim about it -- unexercised. A declared path that is schema valid but
    is not the path Git names must be rejected after the write, not published.
    """
    repo, _ = _repo(tmp_path)
    state = tmp_path / "post-apply-state"
    env = _env(tmp_path)
    # "./allowed.md" clears safe_path (relative, no traversal) and addresses a
    # real allowlisted file, but Git reports the mutation as "allowed.md".
    proposal = _proposal(tmp_path, target={"path": "./allowed.md"})

    result, payload = _run(repo, proposal, state, "--mode", "draft", env=env)

    assert result.returncode != 0
    assert payload["state"] == "rejected"
    assert payload["reason"] == "path_not_allowlisted"
    # Static validation rejects before leasing, so a lease and an isolated
    # worktree are what distinguish this from the pre-build rejection.
    assert payload["lease_id"]
    assert payload["worktree"]
    durable = json.loads(
        (state / "runs" / (payload["fingerprint"] + ".json")).read_text(encoding="utf-8")
    )
    assert durable["transitions"] == ["eligible", "leased", "prepared", "rejected"]
    assert "draft_pr" not in payload
    assert not os.path.exists(env["FIXTURE_GH_LOG"])
    assert (repo / "allowed.md").read_text(encoding="utf-8") == "before\n"
    assert _git("status", "--porcelain", cwd=repo).stdout == ""


def test_plugin_guardrail_candidate_bumps_manifest_and_marketplace_together(tmp_path):
    repo, _ = _repo(tmp_path)
    plugin = repo / "demo-plugin"
    (plugin / ".claude-plugin").mkdir(parents=True)
    (repo / ".claude-plugin").mkdir()
    (plugin / "SKILL.md").write_text("# Demo\n", encoding="utf-8")
    (plugin / ".claude-plugin" / "plugin.json").write_text(
        json.dumps({"name": "demo-plugin", "version": "1.2.3"}, indent=2) + "\n",
        encoding="utf-8",
    )
    (repo / ".claude-plugin" / "marketplace.json").write_text(
        json.dumps(
            {
                "plugins": [
                    {"name": "demo-plugin", "source": "./demo-plugin", "version": "1.2.3"}
                ]
            },
            indent=2,
        )
        + "\n",
        encoding="utf-8",
    )
    _git("add", ".", cwd=repo)
    _git("commit", "-qm", "add plugin fixture", cwd=repo)
    _git("push", "-q", "origin", "HEAD:main", cwd=repo)
    proposal = _proposal(tmp_path, target={"path": "demo-plugin/SKILL.md"})

    result, payload = _run(
        repo,
        proposal,
        tmp_path / "state",
        "--mode",
        "draft",
        env=_env(tmp_path / "env"),
    )

    assert result.returncode == 0, result.stderr
    branch = payload["branch"]
    changed = _git("diff-tree", "--no-commit-id", "--name-only", "-r", branch, cwd=repo).stdout.splitlines()
    assert sorted(changed) == [
        ".claude-plugin/marketplace.json",
        "demo-plugin/.claude-plugin/plugin.json",
        "demo-plugin/SKILL.md",
    ]
    manifest = json.loads(_git("show", f"{branch}:demo-plugin/.claude-plugin/plugin.json", cwd=repo).stdout)
    marketplace = json.loads(_git("show", f"{branch}:.claude-plugin/marketplace.json", cwd=repo).stdout)
    assert manifest["version"] == "1.2.4"
    assert marketplace["plugins"][0]["version"] == "1.2.4"


def test_unexpected_candidate_failure_is_a_durable_failed_terminal_state(tmp_path):
    repo, _ = _repo(tmp_path)
    proposal = _proposal(tmp_path, target={"path": "missing.md"})
    result, payload = _run(repo, proposal, tmp_path / "failed", "--mode", "draft", env=_env(tmp_path))
    assert result.returncode != 0
    assert payload["state"] == "failed"
    assert payload["reason"] == "candidate_target_unavailable"
    assert "draft_pr" not in payload


def test_invalid_utf8_candidate_is_a_typed_terminal_failure(tmp_path):
    repo, _ = _repo(tmp_path)
    (repo / "allowed.md").write_bytes(b"before\xffafter\n")
    _git("add", "allowed.md", cwd=repo)
    _git("commit", "-qm", "add invalid utf8 fixture", cwd=repo)
    _git("push", "-q", "origin", "HEAD:main", cwd=repo)

    result, payload = _run(
        repo,
        _proposal(tmp_path),
        tmp_path / "invalid-utf8-state",
        "--mode",
        "draft",
        env=_env(tmp_path / "invalid-utf8"),
    )

    assert result.returncode != 0
    assert payload["state"] == "failed"
    assert payload["reason"] == "candidate_target_invalid_utf8"
    assert "Traceback" not in result.stderr


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

    for field, bad_value in (("state", []), ("mode", {})):
        typed_state = tmp_path / f"corrupt-{field}-state"
        stopped, partial = _run(
            repo,
            proposal,
            typed_state,
            "--mode",
            "draft",
            "--stop-after",
            "leased",
            env=env,
        )
        assert stopped.returncode != 0
        durable_path = typed_state / "runs" / (partial["fingerprint"] + ".json")
        durable = json.loads(durable_path.read_text(encoding="utf-8"))
        durable[field] = bad_value
        durable_path.write_text(json.dumps(durable), encoding="utf-8")
        resumed, failed = _run(
            repo, proposal, typed_state, "--mode", "draft", env=env
        )
        assert resumed.returncode != 0
        assert failed["state"] == "failed"
        assert failed["reason"] == "state_corrupt"
    assert not os.path.exists(env["FIXTURE_GH_LOG"])

    transitions_state = tmp_path / "corrupt-transitions-state"
    stopped, partial = _run(
        repo,
        proposal,
        transitions_state,
        "--mode",
        "draft",
        "--stop-after",
        "leased",
        env=env,
    )
    assert stopped.returncode != 0
    durable_path = transitions_state / "runs" / (partial["fingerprint"] + ".json")
    durable = json.loads(durable_path.read_text(encoding="utf-8"))
    durable["transitions"] = {"bad": "shape"}
    durable_path.write_text(json.dumps(durable), encoding="utf-8")
    resumed, failed = _run(
        repo, proposal, transitions_state, "--mode", "draft", env=env
    )
    assert resumed.returncode != 0
    assert failed["state"] == "failed"
    assert failed["reason"] == "state_corrupt"


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


def test_terminal_failures_reopen_after_repair_but_completed_drafts_do_not(tmp_path):
    repo, _ = _repo(tmp_path)
    proposal = _proposal(tmp_path)
    state = tmp_path / "retry-state"
    env = _env(tmp_path / "retry")
    dirty = repo / "operator-dirty.txt"
    dirty.write_text("not part of the improvement\n", encoding="utf-8")

    rejected, first = _run(repo, proposal, state, "--mode", "draft", env=env)
    assert rejected.returncode != 0
    assert first["reason"] == "operator_checkout_dirty"

    dirty.unlink()
    retried, completed = _run(repo, proposal, state, "--mode", "draft", env=env)
    assert retried.returncode == 0, retried.stderr
    assert completed["state"] == "draft_created"

    replayed, same = _run(repo, proposal, state, "--mode", "draft", env=env)
    assert replayed.returncode == 0
    assert same["draft_pr"]["id"] == completed["draft_pr"]["id"]
    assert open(env["FIXTURE_GH_LOG"], encoding="utf-8").read().count("pr create") == 1


def test_baseline_terminal_reopens_when_external_validation_is_repaired(tmp_path):
    repo, _ = _repo(tmp_path)
    proposal = _proposal(tmp_path)
    state = tmp_path / "baseline-repair-state"
    env = _env(tmp_path / "baseline-repair")
    env["FIXTURE_EVAL_MODE"] = "noisy"

    rejected, failed = _run(repo, proposal, state, "--mode", "draft", env=env)
    assert rejected.returncode != 0
    assert failed["reason"] == "baseline_failed"

    env.pop("FIXTURE_EVAL_MODE")
    retried, completed = _run(repo, proposal, state, "--mode", "draft", env=env)
    assert retried.returncode == 0, retried.stderr
    assert completed["state"] == "draft_created"


def test_terminal_review_rejection_reopens_after_the_remote_base_advances(tmp_path):
    repo, _ = _repo(tmp_path)
    proposal = _proposal(tmp_path)
    state = tmp_path / "base-advance-state"
    env = _env(tmp_path / "base-advance")
    env["FIXTURE_REVIEW_MODE"] = "reject"

    rejected, failed = _run(repo, proposal, state, "--mode", "draft", env=env)
    assert rejected.returncode != 0
    assert failed["reason"] == "review_requested_changes"
    old_base = failed["base_sha"]

    (repo / "remote-repair.md").write_text("repair\n", encoding="utf-8")
    _git("add", "remote-repair.md", cwd=repo)
    _git("commit", "-qm", "repair base", cwd=repo)
    _git("push", "-q", "origin", "HEAD:main", cwd=repo)
    env.pop("FIXTURE_REVIEW_MODE")

    retried, completed = _run(repo, proposal, state, "--mode", "draft", env=env)
    assert retried.returncode == 0, retried.stderr
    assert completed["state"] == "draft_created"
    assert completed["base_sha"] != old_base


def test_replay_identity_ignores_growing_evidence_for_the_same_candidate(tmp_path):
    repo, _ = _repo(tmp_path)
    state = tmp_path / "state"
    env = _env(tmp_path)
    provenance = {
        "source": "learning-law",
        "source_id": "stable-law",
        "law_key": "stable-law",
        "confidence": 0.93,
        "support": {"episodes": 5, "projects": 3},
        "evidence_ids": ["e1", "e2", "e3"],
    }
    proposal = _proposal(tmp_path, revision=5, provenance=provenance)
    first, initial = _run(repo, proposal, state, "--mode", "draft", env=env)
    assert first.returncode == 0

    provenance = dict(provenance)
    provenance["support"] = {"episodes": 8, "projects": 4}
    provenance["evidence_ids"] = ["e1", "e2", "e3", "e4"]
    proposal = _proposal(tmp_path, revision=8, provenance=provenance)
    replay, evolved = _run(repo, proposal, state, "--mode", "draft", env=env)

    assert replay.returncode == 0
    assert evolved["state"] == "draft_created"
    assert evolved["fingerprint"] == initial["fingerprint"]
    assert evolved["branch"] == initial["branch"]
    assert open(env["FIXTURE_GH_LOG"], encoding="utf-8").read().count("pr create") == 1


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


def test_approving_verdict_with_a_blocking_finding_never_publishes(tmp_path):
    """The verdict word is not the gate; the findings it carries are.

    A reviewer that answers "approve" while reporting a critical, high, or
    medium finding has not cleared the change, and publishing it would open a
    pull request the reviewer itself argued against. Severity is the only thing
    that differs between the rejected cases and the published control below, so
    a regression that trusts the verdict alone cannot pass both halves.
    """
    repo, _ = _repo(tmp_path)
    proposal = _proposal(tmp_path)
    # "HIGH" is included because the engine compares case-folded severities.
    for severity in ("critical", "HIGH", "medium"):
        env = _env(tmp_path / severity)
        env["FIXTURE_REVIEW_FINDING_SEVERITY"] = severity

        result, payload = _run(
            repo, proposal, tmp_path / (severity + "-state"), "--mode", "draft", env=env
        )

        assert result.returncode != 0, severity
        assert payload["state"] == "rejected", severity
        assert payload["reason"] == "review_requested_changes", severity
        assert "draft_pr" not in payload, severity
        assert "published_remote_head" not in payload, severity
        # gh is never invoked at all, so the log file is never created.
        assert not os.path.exists(env["FIXTURE_GH_LOG"]), severity

    low_env = _env(tmp_path / "low")
    low_env["FIXTURE_REVIEW_FINDING_SEVERITY"] = "low"
    accepted, published = _run(
        repo, proposal, tmp_path / "low-state", "--mode", "draft", env=low_env
    )
    assert accepted.returncode == 0, accepted.stderr
    assert published["state"] == "draft_created"
    assert "pr create" in open(low_env["FIXTURE_GH_LOG"], encoding="utf-8").read()


def test_missing_reviewer_binary_fails_closed_before_any_publication(tmp_path):
    """No reachable reviewer means no review, and no review means no draft.

    The independent review is the engine's only external judgement, so an
    unresolvable reviewer command must stop the run at the immutable evaluated
    state rather than degrade into publishing an unreviewed candidate.
    """
    unavailable = {
        # An absolute path that does not exist.
        "absolute": "/nonexistent/legion-improve/legion-delegate",
        # A bare name that is on no PATH entry and has no in-repo fallback.
        "unresolvable": "legion-improve-reviewer-that-is-not-installed",
    }
    for name, configured in unavailable.items():
        fixture = tmp_path / name
        fixture.mkdir()
        repo, _ = _repo(fixture)
        proposal = _proposal(fixture)
        env = _env(fixture / "env")
        reachable = env["LEGION_IMPROVE_REVIEW_BIN"]
        env["LEGION_IMPROVE_REVIEW_BIN"] = configured
        state = fixture / "state"

        result, payload = _run(repo, proposal, state, "--mode", "draft", env=env)

        assert result.returncode != 0, name
        assert payload["state"] == "evaluated", name
        assert payload["reason"] == "independent_review_unavailable", name
        assert "review_receipt" not in payload, name
        assert "draft_pr" not in payload, name
        assert not os.path.exists(env["FIXTURE_GH_LOG"]), name
        assert (
            _git("ls-remote", "origin", "refs/heads/" + payload["branch"], cwd=repo).stdout
            == ""
        ), name

        # Fail-closed, not a dead end: the evaluated state is immutable and the
        # run completes once a reviewer is reachable again.
        env["LEGION_IMPROVE_REVIEW_BIN"] = reachable
        resumed, done = _run(repo, proposal, state, "--mode", "draft", env=env)
        assert resumed.returncode == 0, resumed.stderr
        assert done["state"] == "draft_created", name


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
    assert second_payload["skipped_completed"] == 1
    assert second_payload["results"] == []
    assert not proposal.exists()
    assert open(env["FIXTURE_GH_LOG"], encoding="utf-8").read().count("pr create") == 1


def test_queue_retries_repairable_terminal_proposals_instead_of_discarding_them(tmp_path):
    repo, _ = _repo(tmp_path)
    queue_dir = tmp_path / "retry-queue"
    queue_dir.mkdir()
    proposal = _proposal(queue_dir)
    state = tmp_path / "retry-queue-state"
    env = _env(tmp_path / "retry-queue-env")
    env["FIXTURE_EVAL_MODE"] = "noisy"

    first, failed = _queue(
        repo, queue_dir, state, "--mode", "draft", "--max", "1", env=env
    )
    assert first.returncode != 0
    assert failed["attempted"] == 1
    assert failed["results"][0]["state"] == "rejected"
    assert proposal.exists()

    env.pop("FIXTURE_EVAL_MODE")
    second, completed = _queue(
        repo, queue_dir, state, "--mode", "draft", "--max", "1", env=env
    )
    assert second.returncode == 0, second.stderr
    assert completed["attempted"] == 1
    assert completed["results"][0]["state"] == "draft_created"


def test_queue_quarantines_invalid_entries_and_dry_run_advances_to_later_work(tmp_path):
    repo, _ = _repo(tmp_path)
    env = _env(tmp_path)

    queue_dir = tmp_path / "quarantine-queue"
    queue_dir.mkdir()
    (queue_dir / "000-invalid.json").write_text("{not-json", encoding="utf-8")
    valid = _proposal(queue_dir)
    valid.rename(queue_dir / "zzz-valid.json")
    result, payload = _queue(
        repo,
        queue_dir,
        tmp_path / "quarantine-state",
        "--mode",
        "draft",
        "--max",
        "1",
        env=env,
    )
    assert result.returncode != 0
    assert payload["invalid_entries"] == 1
    assert payload["quarantined"] == 1
    assert payload["attempted"] == 1
    assert payload["results"][0]["state"] == "draft_created"
    assert (queue_dir / "quarantine" / "000-invalid.json.invalid").is_file()

    dry_queue = tmp_path / "dry-queue"
    dry_queue.mkdir()
    first = _proposal(dry_queue, id="dry-first")
    first.rename(dry_queue / "a-first.json")
    second = _proposal(
        dry_queue,
        id="dry-second",
        candidate={
            "operation": "append_markdown_guardrail",
            "content": "Run the second independent workflow check.",
        },
    )
    second.rename(dry_queue / "b-second.json")
    first_run, first_payload = _queue(
        repo,
        dry_queue,
        tmp_path / "dry-state",
        "--mode",
        "dry-run",
        "--max",
        "1",
        env=env,
    )
    second_run, second_payload = _queue(
        repo,
        dry_queue,
        tmp_path / "dry-state",
        "--mode",
        "dry-run",
        "--max",
        "1",
        env=env,
    )
    assert first_run.returncode == second_run.returncode == 0
    assert first_payload["results"][0]["state"] == "reviewed"
    assert second_payload["results"][0]["state"] == "reviewed"
    assert not (dry_queue / "a-first.json").exists()
    assert not (dry_queue / "b-second.json").exists()

    unsafe_queue = tmp_path / "unsafe-quarantine-queue"
    outside = tmp_path / "outside-quarantine"
    unsafe_queue.mkdir()
    outside.mkdir()
    (unsafe_queue / "quarantine").symlink_to(outside, target_is_directory=True)
    invalid = unsafe_queue / "oversized.json"
    invalid.write_text("x" * 65_537, encoding="utf-8")
    unsafe_run, unsafe_payload = _queue(
        repo,
        unsafe_queue,
        tmp_path / "unsafe-quarantine-state",
        "--mode",
        "draft",
        "--max",
        "1",
        env=env,
    )
    assert unsafe_run.returncode != 0
    assert unsafe_payload["invalid_entries"] == 1
    assert unsafe_payload["quarantined"] == 0
    assert invalid.is_file()
    assert list(outside.iterdir()) == []


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


def test_reviewed_head_is_reverified_against_the_candidate_before_publishing(tmp_path):
    """The review receipt is a claim; the reviewed commit is the evidence.

    Between review and publication the engine re-derives the reviewed commit's
    parents, its changed paths, and its patch digest from the candidate
    worktree. Trusting the receipt alone would let anything that moved in that
    window -- a candidate that no longer produces the reviewed diff, or a
    target whose allowlisted path set has changed -- reach a pull request under
    an approval that was never given for it.
    """
    digest_fixture = tmp_path / "digest-mismatch"
    digest_fixture.mkdir()
    repo, _ = _repo(digest_fixture)
    proposal = _proposal(digest_fixture)
    state = digest_fixture / "state"
    env = _env(digest_fixture / "env")
    payload, durable_path, durable = _reviewed_state(repo, proposal, state, env)
    # Restate the reviewed diff as a different, still well-formed digest. The
    # record stays internally consistent, so only the publish-time recheck can
    # notice that the candidate no longer produces the patch that was reviewed.
    replacement = hashlib.sha256(b"a diff that was never reviewed").hexdigest()
    durable["diff_digest"] = replacement
    durable["review_receipt"]["diff_digest"] = replacement
    _reseal_review_receipt(durable["review_receipt"])
    durable_path.write_text(json.dumps(durable), encoding="utf-8")

    blocked, failed = _run(repo, proposal, state, "--mode", "draft", env=env)

    assert blocked.returncode != 0
    assert failed["state"] == "failed"
    assert failed["reason"] == "review_snapshot_mismatch"
    assert "draft_pr" not in failed
    assert not os.path.exists(env["FIXTURE_GH_LOG"])
    assert (
        _git("ls-remote", "origin", "refs/heads/" + payload["branch"], cwd=repo).stdout
        == ""
    )

    # The same gate covers the allowlisted path set, which is derived from the
    # candidate worktree rather than from the record. Planting a plugin
    # manifest above the reviewed target after review widens the policy-mandated
    # path set, so the reviewed commit no longer changes everything it must.
    paths_fixture = tmp_path / "paths-mismatch"
    paths_fixture.mkdir()
    repo, _ = _repo(paths_fixture)
    (repo / "demo-plugin").mkdir()
    (repo / "demo-plugin" / "SKILL.md").write_text("# Demo\n", encoding="utf-8")
    _git("add", ".", cwd=repo)
    _git("commit", "-qm", "add plugin-free skill fixture", cwd=repo)
    _git("push", "-q", "origin", "HEAD:main", cwd=repo)
    proposal = _proposal(paths_fixture, target={"path": "demo-plugin/SKILL.md"})
    state = paths_fixture / "state"
    env = _env(paths_fixture / "env")
    payload, _, _ = _reviewed_state(repo, proposal, state, env)
    candidate = state / "worktrees" / payload["fingerprint"] / "candidate"
    (candidate / "demo-plugin" / ".claude-plugin").mkdir(parents=True)
    (candidate / ".claude-plugin").mkdir()
    (candidate / "demo-plugin" / ".claude-plugin" / "plugin.json").write_text(
        json.dumps({"name": "demo-plugin", "version": "1.2.3"}, indent=2) + "\n",
        encoding="utf-8",
    )
    (candidate / ".claude-plugin" / "marketplace.json").write_text(
        json.dumps(
            {"plugins": [{"name": "demo-plugin", "source": "./demo-plugin", "version": "1.2.3"}]},
            indent=2,
        )
        + "\n",
        encoding="utf-8",
    )

    blocked, failed = _run(repo, proposal, state, "--mode", "draft", env=env)

    assert blocked.returncode != 0
    assert failed["state"] == "failed"
    assert failed["reason"] == "review_snapshot_mismatch"
    assert "draft_pr" not in failed
    assert not os.path.exists(env["FIXTURE_GH_LOG"])
    assert (
        _git("ls-remote", "origin", "refs/heads/" + payload["branch"], cwd=repo).stdout
        == ""
    )


def test_stale_retry_reclaims_only_its_owned_unpublished_branch(tmp_path):
    repo, _ = _repo(tmp_path)
    proposal = _proposal(tmp_path)
    state = tmp_path / "state"
    env = _env(tmp_path)
    env["FIXTURE_GH_MODE"] = "fail-create"

    failed, partial = _run(repo, proposal, state, "--mode", "draft", env=env)
    assert failed.returncode != 0
    old_head = partial["review_receipt"]["reviewed_head_sha"]
    assert partial["published_remote_head"] == old_head
    assert _git("ls-remote", "origin", f"refs/heads/{partial['branch']}", cwd=repo).stdout.startswith(old_head)

    (repo / "base-repair.md").write_text("repaired\n", encoding="utf-8")
    _git("add", "base-repair.md", cwd=repo)
    _git("commit", "-qm", "advance base after draft failure", cwd=repo)
    _git("push", "-q", "origin", "HEAD:main", cwd=repo)

    # Resume from a valid durable stale state, then stop the next generation
    # after review. The remote still contains the first generation's actually
    # published head while the newest review receipt now names a second head.
    durable_path = state / "runs" / f"{partial['fingerprint']}.json"
    durable = json.loads(durable_path.read_text(encoding="utf-8"))
    durable["state"] = "stale"
    durable["reason"] = "base_sha_changed"
    durable["transitions"].append("stale")
    durable_path.write_text(json.dumps(durable), encoding="utf-8")
    stopped, second_generation = _run(
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
    assert second_generation["state"] == "reviewed"
    assert second_generation["published_remote_head"] == old_head
    second_head = second_generation["review_receipt"]["reviewed_head_sha"]
    assert second_head != old_head

    (repo / "second-base-repair.md").write_text("repaired again\n", encoding="utf-8")
    _git("add", "second-base-repair.md", cwd=repo)
    _git("commit", "-qm", "advance base after second review", cwd=repo)
    _git("push", "-q", "origin", "HEAD:main", cwd=repo)

    stale, stale_payload = _run(repo, proposal, state, "--mode", "draft", env=env)
    assert stale.returncode != 0
    assert stale_payload["state"] == "stale"
    assert stale_payload["reason"] != "branch_collision"
    env.pop("FIXTURE_GH_MODE")
    retried, completed = _run(repo, proposal, state, "--mode", "draft", env=env)
    assert retried.returncode == 0, retried.stderr
    assert completed["state"] == "draft_created"
    assert completed["base_sha"] != partial["base_sha"]
    assert completed["review_receipt"]["reviewed_head_sha"] != old_head


def test_created_draft_is_rolled_back_when_base_races_or_verification_fails(tmp_path):
    for mode, expected in (("race-base", "existing_pr_identity_mismatch"), ("fail-view", "draft_pr_verify_failed")):
        fixture = tmp_path / mode
        fixture.mkdir()
        repo, _ = _repo(fixture)
        proposal = _proposal(fixture)
        env = _env(fixture / "env")
        env["FIXTURE_GH_MODE"] = mode

        result, payload = _run(repo, proposal, fixture / "state", "--mode", "draft", env=env)

        assert result.returncode != 0
        assert payload["reason"] == expected
        log = open(env["FIXTURE_GH_LOG"], encoding="utf-8").read()
        assert "pr close https://github.com/fixture/repo/pull/7 --delete-branch" in log
        assert _git("ls-remote", "origin", f"refs/heads/{payload['branch']}", cwd=repo).stdout == ""


def test_failed_pr_rollback_is_durable_and_retried_before_more_publication(tmp_path):
    repo, _ = _repo(tmp_path)
    proposal = _proposal(tmp_path)
    state = tmp_path / "rollback-retry-state"
    env = _env(tmp_path / "rollback-retry-env")
    env["FIXTURE_GH_MODE"] = "race-base-close-once"

    failed, pending = _run(repo, proposal, state, "--mode", "draft", env=env)

    assert failed.returncode != 0
    assert pending["state"] == "reviewed"
    assert pending["reason"] == "draft_pr_rollback_failed"
    assert pending["pending_rollback"]["url"] == "https://github.com/fixture/repo/pull/7"
    assert pending["published_remote_head"] == pending["pending_rollback"]["head_sha"]

    # Even if an outer process error terminalized the run after the rollback
    # receipt was persisted, the next invocation must recover that receipt
    # before publishing or resetting any state.
    durable_path = state / "runs" / f"{pending['fingerprint']}.json"
    durable = json.loads(durable_path.read_text(encoding="utf-8"))
    durable["state"] = "failed"
    durable["reason"] = "internal_operation_failed"
    durable["transitions"].append("failed")
    durable_path.write_text(json.dumps(durable), encoding="utf-8")

    inspected, still_pending = _run(
        repo, proposal, state, "--mode", "dry-run", env=env
    )
    assert inspected.returncode != 0
    assert still_pending["state"] == "reviewed"
    assert still_pending["pending_rollback"] == pending["pending_rollback"]

    candidate = state / "worktrees" / pending["fingerprint"] / "candidate"
    _git("worktree", "remove", "--force", str(candidate), cwd=repo)
    assert not candidate.exists()

    cleaned, stale = _run(repo, proposal, state, "--mode", "draft", env=env)

    assert cleaned.returncode != 0
    assert stale["state"] == "stale"
    assert "pending_rollback" not in stale
    log = open(env["FIXTURE_GH_LOG"], encoding="utf-8").read()
    assert log.count("pr close https://github.com/fixture/repo/pull/7 --delete-branch") == 2
    assert log.count("pr create") == 1

    env.pop("FIXTURE_GH_MODE")
    _git("merge", "--ff-only", "origin/main", cwd=repo)
    resumed, completed = _run(repo, proposal, state, "--mode", "draft", env=env)
    assert resumed.returncode == 0, resumed.stderr
    assert completed["state"] == "draft_created"


def test_closed_or_merged_publication_is_reused_without_duplicate_pr(tmp_path):
    for mode, draft in (("existing-closed", True), ("existing-merged", False)):
        fixture = tmp_path / mode
        fixture.mkdir()
        repo, _ = _repo(fixture)
        env = _env(fixture / "env")
        env["FIXTURE_GH_MODE"] = mode
        result, payload = _run(
            repo,
            _proposal(fixture),
            fixture / "state",
            "--mode",
            "draft",
            env=env,
        )
        assert result.returncode == 0, result.stderr
        assert payload["draft_pr"]["draft"] is draft
        assert "pr create" not in open(env["FIXTURE_GH_LOG"], encoding="utf-8").read()
def test_existing_draft_pr_must_match_reviewed_base_branch_and_head(tmp_path):
    repo, _ = _repo(tmp_path)
    proposal = _proposal(tmp_path)

    good_env = _env(tmp_path / "existing-good")
    good_env["FIXTURE_GH_MODE"] = "existing-good"
    accepted, payload = _run(
        repo,
        proposal,
        tmp_path / "existing-good-state",
        "--mode",
        "draft",
        env=good_env,
    )
    assert accepted.returncode == 0, accepted.stderr
    assert payload["state"] == "draft_created"
    assert "pr create" not in open(good_env["FIXTURE_GH_LOG"], encoding="utf-8").read()

    bad_env = _env(tmp_path / "existing-wrong")
    bad_env["FIXTURE_GH_MODE"] = "existing-wrong"
    rejected, failed = _run(
        repo,
        proposal,
        tmp_path / "existing-wrong-state",
        "--mode",
        "draft",
        env=bad_env,
    )
    assert rejected.returncode != 0
    assert failed["state"] == "failed"
    assert failed["reason"] == "existing_pr_already_published"
    assert "pr create" not in open(bad_env["FIXTURE_GH_LOG"], encoding="utf-8").read()

    body_env = _env(tmp_path / "existing-body-wrong")
    body_env["FIXTURE_GH_MODE"] = "existing-body-wrong"
    body_rejected, body_failed = _run(
        repo,
        proposal,
        tmp_path / "existing-body-wrong-state",
        "--mode",
        "draft",
        env=body_env,
    )
    assert body_rejected.returncode != 0
    assert body_failed["state"] == "failed"
    assert body_failed["reason"] == "existing_pr_already_published"
    assert "pr create" not in open(body_env["FIXTURE_GH_LOG"], encoding="utf-8").read()


def test_inspect_rejects_traversal_and_corrupt_records_without_echoing_them(tmp_path):
    state = tmp_path / "state"
    outside = tmp_path / "outside"
    outside.mkdir()
    secret = "TOP_SECRET_INSPECT_PAYLOAD"
    (outside / "leak.json").write_text(
        json.dumps({"schema": "hostile", "secret": secret}), encoding="utf-8"
    )

    traversal = subprocess.run(
        [
            "bash",
            CLI,
            "inspect",
            "--state-dir",
            str(state),
            "--fingerprint",
            "../../outside/leak",
            "--json",
        ],
        text=True,
        capture_output=True,
        check=False,
    )
    assert traversal.returncode != 0
    assert json.loads(traversal.stdout)["reason"] == "invalid_fingerprint"
    assert secret not in traversal.stdout

    fingerprint = "a" * 64
    durable = state / "runs" / f"{fingerprint}.json"
    durable.parent.mkdir(parents=True)
    durable.write_text(
        json.dumps({"schema": "hostile", "secret": secret}), encoding="utf-8"
    )
    corrupt = subprocess.run(
        [
            "bash",
            CLI,
            "inspect",
            "--state-dir",
            str(state),
            "--fingerprint",
            fingerprint,
            "--json",
        ],
        text=True,
        capture_output=True,
        check=False,
    )
    assert corrupt.returncode != 0
    assert json.loads(corrupt.stdout)["reason"] == "state_corrupt"
    assert secret not in corrupt.stdout


def test_completed_draft_identity_fields_are_deterministic_and_tamper_evident(tmp_path):
    repo, _ = _repo(tmp_path)
    proposal = _proposal(tmp_path)
    state = tmp_path / "state"
    env = _env(tmp_path / "env")
    result, payload = _run(repo, proposal, state, "--mode", "draft", env=env)
    assert result.returncode == 0, result.stderr
    durable_path = state / "runs" / f"{payload['fingerprint']}.json"
    original = json.loads(durable_path.read_text(encoding="utf-8"))

    for field, value in (
        ("id", "0" * 24),
        ("body", "type-correct but unreviewed body"),
        ("url", "https://github.com/fixture/repo/pull/99"),
    ):
        tampered = json.loads(json.dumps(original))
        tampered["draft_pr"][field] = value
        durable_path.write_text(json.dumps(tampered), encoding="utf-8")
        inspected = subprocess.run(
            [
                "bash", CLI, "inspect", "--state-dir", str(state),
                "--fingerprint", payload["fingerprint"], "--json",
            ],
            text=True,
            capture_output=True,
            check=False,
        )
        assert inspected.returncode != 0
        error = json.loads(inspected.stdout)
        assert error == {
            "schema": "legion.improvement-error.v1",
            "command": "inspect",
            "status": "error",
            "reason": "state_corrupt",
        }
    durable_path.write_text(json.dumps(original), encoding="utf-8")


def test_github_repository_is_derived_from_the_origin_remote_when_unpinned(
    tmp_path, monkeypatch
):
    """The repository a draft is opened against comes from the origin remote.

    This is the one branch the black-box tests cannot reach: they all pin
    LEGION_IMPROVE_GITHUB_REPOSITORY, and a run whose origin really is a GitHub
    URL cannot complete against a local fixture remote. Every other test would
    therefore stay green while the derivation that decides *where* a pull
    request is published silently stopped recognising a supported remote form
    -- or started accepting one that is not a GitHub repository at all.
    """
    import importlib.util

    module_path = os.path.join(
        ROOT, "legion-observability", "scripts", "legion-improve.py"
    )
    spec = importlib.util.spec_from_file_location("legion_improve", module_path)
    improve = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(improve)
    monkeypatch.delenv("LEGION_IMPROVE_GITHUB_REPOSITORY", raising=False)

    repo = tmp_path / "remote-forms"
    repo.mkdir()
    _git("init", "-q", cwd=repo)
    # No origin at all: nothing to derive, and nothing may be invented.
    assert improve._github_repository(repo) == ""

    _git("remote", "add", "origin", "https://github.com/org/repo.git", cwd=repo)
    for url, expected in (
        ("https://github.com/org/repo.git", "org/repo"),
        ("git@github.com:org/repo.git", "org/repo"),
        ("ssh://git@github.com/org/repo", "org/repo"),
        ("https://github.com/org/repo/", "org/repo"),
        # Not a GitHub repository URL: the publish hop must stop with
        # gh_unavailable rather than aim at a host or path nobody configured.
        ("https://gitlab.com/org/repo.git", ""),
        ("https://github.com/org/repo/extra", ""),
        ("https://github.com/org", ""),
    ):
        _git("remote", "set-url", "origin", url, cwd=repo)
        assert improve._github_repository(repo) == expected, url


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


def test_regression_terminal_reopens_after_external_validator_repair(tmp_path):
    repo, _ = _repo(tmp_path)
    proposal = _proposal(tmp_path)
    state = tmp_path / "regression-repair"
    env = _env(tmp_path / "env")
    env["FIXTURE_EVAL_MODE"] = "regression"

    rejected, first = _run(repo, proposal, state, "--mode", "draft", env=env)
    assert rejected.returncode != 0
    assert first["reason"] == "regression"

    env.pop("FIXTURE_EVAL_MODE")
    retried, completed = _run(repo, proposal, state, "--mode", "draft", env=env)
    assert retried.returncode == 0, retried.stderr
    assert completed["state"] == "draft_created"


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


def test_reconciliation_wait_is_not_reported_as_a_queue_failure(tmp_path):
    """A deliberate wait must not look like an error to the daily refresh.

    refresh.sh escalates any nonzero exit from `legion-improve queue` into a
    high-severity self-learn failure record, so counting the publish
    reconciliation window as a failure would pollute the learning signal this
    engine exists to protect -- possibly on consecutive days for one proposal.

    Driven through the real CLI: a record is parked in the reviewed state with a
    publish intent whose pull request no listing will corroborate, which is
    exactly the state a crash between `gh pr create` and its receipt leaves
    behind.
    """
    repo, _ = _repo(tmp_path)
    state = tmp_path / "state"
    queue_dir = tmp_path / "queue"
    queue_dir.mkdir()
    env = _env(tmp_path)
    proposal = _proposal(tmp_path)
    (queue_dir / "a-first.json").write_text(
        proposal.read_text(encoding="utf-8"), encoding="utf-8"
    )

    # Reach the reviewed state, then plant the publish intent the reconciliation
    # window keys on, and make the pull-request listing come back empty.
    _, partial = _run(
        repo, proposal, state, "--mode", "draft", "--stop-after", "reviewed", env=env
    )
    record_path = state / "runs" / (partial["fingerprint"] + ".json")
    record = json.loads(record_path.read_text(encoding="utf-8"))
    record["publish_attempt"] = {
        "repository": env["LEGION_IMPROVE_GITHUB_REPOSITORY"],
        "head_branch": record["branch"],
        "head_sha": record["review_receipt"]["reviewed_head_sha"],
    }
    record_path.write_text(json.dumps(record), encoding="utf-8")

    result, payload = _queue(
        repo, queue_dir, state, "--mode", "draft", "--max", "1", env=env
    )

    assert payload["results"], payload
    assert payload["results"][0]["status"] == "waiting", payload
    assert payload["failed"] == 0, payload
    assert result.returncode == 0, result.stderr
    assert "pr create" not in open(env["FIXTURE_GH_LOG"], encoding="utf-8").read()
