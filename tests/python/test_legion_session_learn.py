import importlib.util
import json
import os
import subprocess
import sys
import time

HERE = os.path.dirname(__file__)
PATH = os.path.join(
    HERE, "..", "..", "legion-observability", "scripts", "legion-session-learn.py"
)
SPEC = importlib.util.spec_from_file_location("legion_session_learn", PATH)
lsl = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = lsl
SPEC.loader.exec_module(lsl)


def test_scan_classifies_dead_seams_and_provider_truth(tmp_path):
    memory = tmp_path / ".claude" / "projects" / "repo" / "memory" / "project_moneyball.md"
    memory.parent.mkdir(parents=True)
    memory.write_text(
        """
Moneyball review found seams wired but dead: Orchestrator, CostMeter and
ResearchRunner were defined+tested but had zero domain callers.

Vercel deploy gotcha: Root Directory = apps/web, buildCommand did not apply
turbo deps, stale VERCEL_TOKEN blocked CLI auth, and GitHub Packages returned 403.
""",
        encoding="utf-8",
    )
    now = time.time()
    os.utime(memory, (now, now))

    result = lsl.scan(tmp_path, days=1)
    categories = {candidate["category"]: candidate for candidate in result["candidates"]}

    assert "seam-consumption" in categories
    assert "zero domain callers" in " ".join(categories["seam-consumption"]["matched_patterns"])
    assert "provider-truth-preflight" in categories
    assert categories["provider-truth-preflight"]["entity"] == "skill:legion-orchestrate"


def test_scan_jsonl_and_record_candidates(tmp_path):
    session = tmp_path / ".codex" / "sessions" / "2026" / "06" / "22" / "session.jsonl"
    session.parent.mkdir(parents=True)
    session.write_text(
        json.dumps(
            {
                "message": {
                    "role": "assistant",
                    "content": (
                        "Cinematic landing review: require screenshot evidence on mobile "
                        "and reduced-motion before declaring done."
                    ),
                }
            }
        )
        + "\n",
        encoding="utf-8",
    )
    now = time.time()
    os.utime(session, (now, now))

    result = lsl.scan(tmp_path, days=1, queries=["landing"])
    assert [candidate["category"] for candidate in result["candidates"]] == [
        "visual-delivery-gate"
    ]

    log_root = tmp_path / "logs" / "legion"
    outcomes = lsl.record_candidates(result["candidates"], str(log_root))

    assert outcomes[0]["schema"] == "legion.outcome.v1"
    assert outcomes[0]["source"] == "session-learn"
    assert outcomes[0]["target_type"] == "skill"
    path = log_root / "self-learn" / "outcomes.jsonl"
    assert path.exists()
    assert json.loads(path.read_text(encoding="utf-8").strip())["metadata"]["category"] == (
        "visual-delivery-gate"
    )


def test_scan_codex_user_correction_feedback(tmp_path):
    session = tmp_path / ".codex" / "sessions" / "2026" / "06" / "26" / "session.jsonl"
    session.parent.mkdir(parents=True)
    session.write_text(
        json.dumps(
            {
                "type": "event_msg",
                "payload": {
                    "type": "agent_message",
                    "message": "I should have linked the exact repo in the credits.",
                },
            }
        )
        + "\n"
        + json.dumps(
            {
                "type": "event_msg",
                "payload": {
                    "type": "user_message",
                    "message": (
                        "U should have linked https://github.com/svineet/harness-bench. "
                        "Did we even refer to that Harness Bench paper?"
                    ),
                },
            }
        )
        + "\n",
        encoding="utf-8",
    )
    now = time.time()
    os.utime(session, (now, now))

    result = lsl.scan(
        tmp_path,
        days=1,
        queries=["harness-bench"],
        show_evidence=True,
    )
    categories = {candidate["category"]: candidate for candidate in result["candidates"]}

    assert "user-correction-feedback" in categories
    correction = categories["user-correction-feedback"]
    assert correction["entity"] == "plugin:legion-observability"
    assert correction["evidence"][0]["role"] == "user"
    assert "svineet/harness-bench" in correction["evidence"][0]["snippet"]


def test_scan_attributes_long_primary_turn_from_structural_events(tmp_path, monkeypatch):
    session = tmp_path / ".codex" / "sessions" / "2026" / "08" / "11" / "session.jsonl"
    session.parent.mkdir(parents=True)
    records = [
        {
            "timestamp": "2026-08-11T08:49:45.997Z",
            "type": "session_meta",
            "payload": {
                "session_id": "session-a",
                "legion_run_id": "private-run-correlation-id",
            },
        },
        {
            "timestamp": "2026-08-11T08:49:46.000Z",
            "type": "event_msg",
            "payload": {"type": "task_started", "turn_id": "turn-a"},
        },
        {
            "timestamp": "2026-08-11T08:50:00.000Z",
            "type": "response_item",
            "payload": {"type": "function_call", "name": "exec", "call_id": "call-a"},
        },
        {
            "timestamp": "2026-08-11T21:19:50.000Z",
            "type": "response_item",
            "payload": {"type": "function_call", "name": "wait", "call_id": "call-b"},
        },
        {
            "timestamp": "2026-08-11T21:20:06.783Z",
            "type": "event_msg",
            "payload": {
                "type": "task_complete",
                "turn_id": "turn-a",
                "duration_ms": 45_020_786,
            },
        },
        {
            "timestamp": "2026-08-12T09:00:00.000Z",
            "type": "event_msg",
            "payload": {
                "type": "user_message",
                "message": "Why did this task keep running for the whole day?",
            },
        },
    ]
    session.write_text(
        "".join(json.dumps(record) + "\n" for record in records),
        encoding="utf-8",
    )

    scans = 0
    original_iter = lsl.legion_session_io.iter_jsonl_objects

    def counted_iter(*args, **kwargs):
        nonlocal scans
        scans += 1
        yield from original_iter(*args, **kwargs)

    monkeypatch.setattr(lsl.legion_session_io, "iter_jsonl_objects", counted_iter)

    result = lsl.scan(tmp_path, days=0, roles={"user"})
    candidates = {item["category"]: item for item in result["candidates"]}
    convergence = candidates["primary-turn-convergence"]
    metrics = convergence["evidence"][0]["session_metrics"]

    assert metrics["longest_turn_duration_ms"] == 45_020_786
    assert metrics["tool_call_count"] == 2
    assert len(metrics["legion_run_ids"]) == 1
    assert metrics["legion_run_ids"][0] != "private-run-correlation-id"
    assert "private-run-correlation-id" not in json.dumps(result)
    assert scans == 2  # bounded metadata inspection + the primary record pass
    assert convergence["entity"] == "skill:legion-orchestrate"


def test_assistant_correction_words_do_not_trigger_user_feedback(tmp_path):
    session = tmp_path / ".codex" / "sessions" / "2026" / "06" / "26" / "assistant.jsonl"
    session.parent.mkdir(parents=True)
    session.write_text(
        json.dumps(
            {
                "type": "event_msg",
                "payload": {
                    "type": "agent_message",
                    "message": "I should have linked the exact repo and used the wrong source.",
                },
            }
        )
        + "\n",
        encoding="utf-8",
    )
    now = time.time()
    os.utime(session, (now, now))

    result = lsl.scan(tmp_path, days=1)

    assert "user-correction-feedback" not in {
        candidate["category"] for candidate in result["candidates"]
    }


def test_oversized_jsonl_session_is_streamed_not_skipped(tmp_path):
    session = tmp_path / ".codex" / "sessions" / "2026" / "06" / "22" / "large.jsonl"
    session.parent.mkdir(parents=True)
    message = {
        "message": {
            "role": "assistant",
            "content": "seams wired but dead with zero domain callers " + ("padding " * 1200),
        }
    }
    session.write_text(json.dumps(message) + "\n", encoding="utf-8")
    now = time.time()
    os.utime(session, (now, now))

    result = lsl.scan(tmp_path, days=1, max_file_mb=0.001)

    assert result["files_scanned"] == 1
    assert result["files_skipped"] == 0
    assert result["candidates"][0]["category"] == "seam-consumption"


def test_default_evidence_and_recorded_outcome_are_privacy_safe(tmp_path):
    repo = tmp_path / "repo"
    repo.mkdir()
    session = tmp_path / ".codex" / "sessions" / "session.jsonl"
    session.parent.mkdir(parents=True)
    secret = "not-a-real-secret-value"
    session.write_text(
        json.dumps(
            {
                "type": "session_meta",
                "payload": {"cwd": str(repo), "session_id": "session-private"},
            }
        )
        + "\n"
        + json.dumps(
            {
                "type": "event_msg",
                "payload": {
                    "type": "agent_message",
                    "message": (
                        "Cinematic landing screenshot review on mobile and reduced-motion; "
                        f"api_key={secret}"
                    ),
                },
            }
        )
        + "\n",
        encoding="utf-8",
    )

    result = lsl.scan(tmp_path, days=0, repo=repo, queries=[secret])
    evidence = result["candidates"][0]["evidence"][0]

    assert result["schema"] == "legion.session-learning.scan.v2"
    assert result["scope"]["repo_scoped"] is True
    assert "home" not in result
    assert "source_path" not in evidence
    assert "snippet" not in evidence
    assert evidence["evidence_id"]
    assert result["query_count"] == 1
    assert result["queries"] == []
    assert secret not in json.dumps(result)
    assert str(tmp_path) not in json.dumps(result)

    outcomes = lsl.record_candidates(result["candidates"], str(tmp_path / "logs"))
    outcome = outcomes[0]
    assert outcome["source_path"] == ""
    assert secret not in json.dumps(outcome)
    assert str(tmp_path) not in json.dumps(outcome)
    assert outcome["metadata"]["evidence_ids"] == [evidence["evidence_id"]]


def test_default_recording_cli_hides_log_and_source_paths(tmp_path, capsys):
    session = tmp_path / ".codex" / "sessions" / "session.jsonl"
    session.parent.mkdir(parents=True)
    session.write_text(
        json.dumps(
            {
                "type": "event_msg",
                "payload": {
                    "type": "user_message",
                    "message": "U should have linked the wrong attribution source.",
                },
            }
        )
        + "\n",
        encoding="utf-8",
    )
    logs = tmp_path / "private-logs"

    status = lsl.main(
        [
            "--home",
            str(tmp_path),
            "--logs",
            str(logs),
            "--lookback-days",
            "0",
            "--record",
            "--json",
        ]
    )
    payload = json.loads(capsys.readouterr().out)

    assert status == 0
    assert payload["outcomes_path"] == ""
    assert payload["outcomes_id"]
    assert str(tmp_path) not in json.dumps(payload)
    recorded = json.loads(
        (logs / "self-learn" / "outcomes.jsonl").read_text(encoding="utf-8")
    )
    assert recorded["source_path"] == ""
    assert str(tmp_path) not in json.dumps(recorded)


def test_repo_scoped_cli_resolves_recording_state_from_repo(tmp_path, monkeypatch, capsys):
    repo = tmp_path / "repo"
    repo.mkdir()
    calls = []
    logs = tmp_path / "resolved-state"

    def resolve_state(path):
        calls.append(path)
        return {"state_root": str(logs)}

    monkeypatch.setattr(lsl.legion_state, "resolve_state", resolve_state)

    status = lsl.main(
        [
            "--home",
            str(tmp_path),
            "--repo",
            str(repo),
            "--lookback-days",
            "0",
            "--record",
            "--json",
        ]
    )
    json.loads(capsys.readouterr().out)

    assert status == 0
    assert calls == [str(repo.resolve())]


def test_show_evidence_uses_redacted_snippets_and_relative_paths(tmp_path):
    session = tmp_path / ".codex" / "sessions" / "session.jsonl"
    session.parent.mkdir(parents=True)
    secret = "abcdefghijklmnop"
    session.write_text(
        json.dumps(
            {
                "type": "event_msg",
                "payload": {
                    "type": "agent_message",
                    "message": (
                        f"Cinematic landing screenshot at {tmp_path}/repo; "
                        f"access_token={secret}"
                    ),
                },
            }
        )
        + "\n",
        encoding="utf-8",
    )

    result = lsl.scan(tmp_path, days=0, show_evidence=True)
    evidence = result["candidates"][0]["evidence"][0]

    assert evidence["source_path"] == ".codex/sessions/session.jsonl"
    assert "~" in evidence["snippet"]
    assert "<redacted>" in evidence["snippet"]
    assert secret not in evidence["snippet"]

    outcome = lsl.record_candidates(
        result["candidates"], str(tmp_path / "recorded")
    )[0]
    assert outcome["source_path"] == ""
    assert "Cinematic landing" not in outcome["evidence"]
    assert secret not in json.dumps(outcome)
    assert str(tmp_path) not in json.dumps(outcome)


def test_show_evidence_redacts_compound_credentials_and_token_shapes(tmp_path):
    session = tmp_path / ".codex" / "sessions" / "session.jsonl"
    session.parent.mkdir(parents=True)
    secrets = [
        "compound-client-secret",
        "url-password",
        "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMN123456",
        "eyJabcdefghijk.abcdefghijkl.abcdefghijkl",
        "private-key-material",
    ]
    message = (
        "Cinematic landing screenshot review on mobile. "
        f"client_secret={secrets[0]} "
        f"https://operator:{secrets[1]}@example.test/private "
        f"token={secrets[2]} {secrets[3]} "
        "-----BEGIN PRIVATE KEY-----\n"
        f"{secrets[4]}\n"
        "-----END PRIVATE KEY-----"
    )
    session.write_text(
        json.dumps(
            {
                "type": "event_msg",
                "payload": {"type": "agent_message", "message": message},
            }
        )
        + "\n",
        encoding="utf-8",
    )

    result = lsl.scan(tmp_path, days=0, show_evidence=True)
    rendered = json.dumps(result)

    assert "<redacted" in rendered
    assert all(secret not in rendered for secret in secrets)


def test_repo_harness_source_and_role_filters_use_session_metadata(tmp_path):
    repo_a = tmp_path / "repo-a"
    repo_b = tmp_path / "repo-b"
    repo_a.mkdir()
    repo_b.mkdir()
    sessions = tmp_path / ".codex" / "sessions"
    sessions.mkdir(parents=True)

    for name, repo, message in (
        (
            "a.jsonl",
            repo_a,
            "U should have linked the wrong attribution source for alpha.",
        ),
        (
            "b.jsonl",
            repo_b,
            "U should have linked the wrong attribution source for beta.",
        ),
    ):
        (sessions / name).write_text(
            json.dumps(
                {
                    "type": "session_meta",
                    "payload": {"cwd": str(repo), "session_id": name},
                }
            )
            + "\n"
            + json.dumps(
                {
                    "type": "event_msg",
                    "payload": {"type": "user_message", "message": message},
                }
            )
            + "\n"
            + json.dumps(
                {
                    "type": "event_msg",
                    "payload": {
                        "type": "agent_message",
                        "message": "Cinematic landing screenshot review on mobile.",
                    },
                }
            )
            + "\n",
            encoding="utf-8",
        )

    result = lsl.scan(
        tmp_path,
        days=0,
        repo=repo_a,
        harnesses={"codex"},
        roles={"user"},
        source_kinds={"codex-session"},
    )
    categories = {candidate["category"]: candidate for candidate in result["candidates"]}

    assert result["files_scanned"] == 1
    assert result["files_filtered"]["repo"] == 1
    assert result["records_filtered_by_role"] == 1
    assert set(categories) == {"user-correction-feedback"}
    assert categories["user-correction-feedback"]["evidence_count"] == 1


def test_query_matches_message_content_not_source_paths(tmp_path):
    note = (
        tmp_path
        / ".claude"
        / "projects"
        / "repo"
        / "memory"
        / "project_moneyball.md"
    )
    note.parent.mkdir(parents=True)
    note.write_text(
        "Cinematic landing screenshot review on mobile.",
        encoding="utf-8",
    )

    result = lsl.scan(tmp_path, days=0, queries=["moneyball"])

    assert result["files_scanned"] == 1
    assert result["query_count"] == 1
    assert result["candidates"] == []


def test_repo_scope_matches_external_worktree_by_normalized_git_remote(tmp_path):
    repo = tmp_path / "repo"
    repo.mkdir()
    subprocess.run(["git", "-C", str(repo), "init", "-q"], check=True)
    subprocess.run(
        [
            "git",
            "-C",
            str(repo),
            "remote",
            "add",
            "origin",
            "git@github.com:acme/widgets.git",
        ],
        check=True,
    )
    session = tmp_path / ".codex" / "sessions" / "remote.jsonl"
    session.parent.mkdir(parents=True)
    session.write_text(
        json.dumps(
            {
                "type": "session_meta",
                "payload": {
                    "cwd": "/isolated/worktree",
                    "git": {
                        "repository_url": "https://github.com/acme/widgets.git"
                    },
                    "session_id": "remote-session",
                },
            }
        )
        + "\n"
        + json.dumps(
            {
                "type": "event_msg",
                "payload": {
                    "type": "user_message",
                    "message": "U should have linked the wrong attribution source.",
                },
            }
        )
        + "\n",
        encoding="utf-8",
    )

    result = lsl.scan(tmp_path, days=0, repo=repo)

    assert result["files_scanned"] == 1
    assert result["files_filtered"]["repo"] == 0
    assert result["candidates"][0]["category"] == "user-correction-feedback"


def test_repo_scope_resolves_remote_from_sibling_checkout_cwd(tmp_path):
    repo = tmp_path / "repo"
    sibling = tmp_path / "repo-sibling"
    unrelated = tmp_path / "unrelated"
    for path, remote in (
        (repo, "git@github.com:acme/widgets.git"),
        (sibling, "https://github.com/acme/widgets.git"),
        (unrelated, "https://github.com/acme/other.git"),
    ):
        path.mkdir()
        subprocess.run(["git", "-C", str(path), "init", "-q"], check=True)
        subprocess.run(
            ["git", "-C", str(path), "remote", "add", "origin", remote],
            check=True,
        )

    sessions = tmp_path / ".codex" / "sessions"
    sessions.mkdir(parents=True)
    for name, cwd, suffix in (
        ("sibling.jsonl", sibling, "matching sibling"),
        ("other.jsonl", unrelated, "unrelated checkout"),
    ):
        (sessions / name).write_text(
            json.dumps(
                {
                    "type": "session_meta",
                    "payload": {"cwd": str(cwd), "session_id": name},
                }
            )
            + "\n"
            + json.dumps(
                {
                    "type": "event_msg",
                    "payload": {
                        "type": "user_message",
                        "message": (
                            "U should have linked the wrong attribution source for "
                            f"{suffix}."
                        ),
                    },
                }
            )
            + "\n",
            encoding="utf-8",
        )

    lsl._repository_urls_for_path.cache_clear()
    result = lsl.scan(tmp_path, days=0, repo=repo, show_evidence=True)
    rendered = json.dumps(result)

    assert result["files_scanned"] == 1
    assert result["files_filtered"]["repo"] == 1
    assert "matching sibling" in rendered
    assert "unrelated checkout" not in rendered


def test_default_filters_subagents_benchmarks_catalogs_and_tool_results(tmp_path):
    sessions = tmp_path / ".codex" / "sessions"
    sessions.mkdir(parents=True)

    main = sessions / "main.jsonl"
    main.write_text(
        json.dumps(
            {
                "type": "response_item",
                "payload": {
                    "type": "message",
                    "role": "developer",
                    "content": [
                        {
                            "type": "text",
                            "text": "Cinematic landing screenshot mobile reduced-motion catalog.",
                        }
                    ],
                },
            }
        )
        + "\n"
        + json.dumps(
            {
                "type": "event_msg",
                "payload": {
                    "type": "user_message",
                    "message": "U should have linked the wrong attribution source for main.",
                },
            }
        )
        + "\n"
        + json.dumps(
            {
                "message": {
                    "role": "user",
                    "content": [
                        {
                            "type": "tool_result",
                            "content": "Cinematic landing screenshot mobile reduced-motion tool output.",
                        }
                    ],
                }
            }
        )
        + "\n",
        encoding="utf-8",
    )

    subagent = sessions / "subagent.jsonl"
    subagent.write_text(
        json.dumps(
            {
                "type": "session_meta",
                "payload": {
                    "agent_path": "/root/audit",
                    "parent_thread_id": "parent",
                    "session_id": "subagent",
                },
            }
        )
        + "\n"
        + json.dumps(
            {
                "type": "event_msg",
                "payload": {
                    "type": "user_message",
                    "message": "U should have linked the wrong attribution source for subagent.",
                },
            }
        )
        + "\n",
        encoding="utf-8",
    )

    benchmark = sessions / "benchmark.jsonl"
    benchmark.write_text(
        json.dumps(
            {
                "type": "session_meta",
                "payload": {"originator": "legion-bench", "session_id": "benchmark"},
            }
        )
        + "\n"
        + json.dumps(
            {
                "type": "event_msg",
                "payload": {
                    "type": "user_message",
                    "message": "U should have linked the wrong attribution source for benchmark.",
                },
            }
        )
        + "\n",
        encoding="utf-8",
    )

    result = lsl.scan(tmp_path, days=0)
    categories = {candidate["category"]: candidate for candidate in result["candidates"]}

    assert result["files_filtered"]["subagent"] == 1
    assert result["files_filtered"]["benchmark"] == 1
    assert result["records_filtered_by_role"] == 1
    assert set(categories) == {"user-correction-feedback"}
    assert categories["user-correction-feedback"]["evidence_count"] == 1

    inclusive = lsl.scan(
        tmp_path,
        days=0,
        include_subagents=True,
        include_benchmarks=True,
    )
    correction = {
        candidate["category"]: candidate for candidate in inclusive["candidates"]
    }["user-correction-feedback"]
    assert correction["evidence_count"] == 3

    developer_catalog = lsl.scan(tmp_path, days=0, roles={"developer"})
    assert [candidate["category"] for candidate in developer_catalog["candidates"]] == [
        "visual-delivery-gate"
    ]

    with_tools = lsl.scan(
        tmp_path,
        days=0,
        roles={"user"},
        include_tool_results=True,
    )
    assert "visual-delivery-gate" in {
        candidate["category"] for candidate in with_tools["candidates"]
    }


def test_equivalent_codex_records_are_deduplicated(tmp_path):
    session = tmp_path / ".codex" / "sessions" / "session.jsonl"
    session.parent.mkdir(parents=True)
    message = "U should have linked the wrong attribution source."
    session.write_text(
        json.dumps(
            {
                "type": "response_item",
                "payload": {
                    "type": "message",
                    "role": "user",
                    "content": [{"type": "input_text", "text": message}],
                },
            }
        )
        + "\n"
        + json.dumps(
            {
                "type": "event_msg",
                "payload": {"type": "user_message", "message": message},
            }
        )
        + "\n",
        encoding="utf-8",
    )

    result = lsl.scan(tmp_path, days=0)
    correction = result["candidates"][0]

    assert result["records_scanned"] == 2
    assert result["records_deduplicated"] == 1
    assert correction["evidence_count"] == 1


def test_equivalent_corrections_from_distinct_sessions_remain_distinct_evidence(tmp_path):
    sessions = tmp_path / ".codex" / "sessions"
    sessions.mkdir(parents=True)
    message = "U should have linked the wrong attribution source."
    for index in range(2):
        (sessions / f"{index}.jsonl").write_text(
            json.dumps(
                {
                    "type": "session_meta",
                    "payload": {"session_id": f"session-{index}"},
                }
            )
            + "\n"
            + json.dumps(
                {
                    "type": "event_msg",
                    "payload": {"type": "user_message", "message": message},
                }
            )
            + "\n",
            encoding="utf-8",
        )

    result = lsl.scan(tmp_path, days=0)
    correction = result["candidates"][0]

    assert result["records_deduplicated"] == 0
    assert correction["evidence_count"] == 2
    assert correction["source_count"] == 2
    assert len(correction["source_ids"]) == 2


def test_session_limit_keeps_only_newest_eligible_sources(tmp_path):
    sessions = tmp_path / ".codex" / "sessions"
    sessions.mkdir(parents=True)
    old = sessions / "old.jsonl"
    new = sessions / "new.jsonl"
    old.write_text(
        json.dumps(
            {
                "type": "event_msg",
                "payload": {
                    "type": "agent_message",
                    "message": "Seams wired but dead with zero domain callers.",
                },
            }
        )
        + "\n",
        encoding="utf-8",
    )
    new.write_text(
        json.dumps(
            {
                "type": "event_msg",
                "payload": {
                    "type": "agent_message",
                    "message": "Cinematic landing screenshot review on mobile.",
                },
            }
        )
        + "\n",
        encoding="utf-8",
    )
    now = time.time()
    os.utime(old, (now - 20, now - 20))
    os.utime(new, (now, now))

    result = lsl.scan(tmp_path, days=0, session_limit=1)

    assert result["files_discovered"] == 2
    assert result["files_scanned"] == 1
    assert result["files_limited"] == 1
    assert [candidate["category"] for candidate in result["candidates"]] == [
        "visual-delivery-gate"
    ]


def test_session_rules_cover_review_validation_worktree_and_policy_failures(tmp_path):
    session = tmp_path / ".codex" / "sessions" / "session.jsonl"
    session.parent.mkdir(parents=True)
    messages = [
        "Review was interrupted and produced a missing review verdict.",
        "The clean test rerun stalled because of inherited LEGION_STATE_ROOT.",
        "Worktree creation failed with worktree_setup_failed.",
        "The harness did not use Legion and invoked raw codex instead.",
    ]
    session.write_text(
        "\n".join(
            json.dumps(
                {
                    "type": "event_msg",
                    "payload": {"type": "agent_message", "message": message},
                }
            )
            for message in messages
        )
        + "\n",
        encoding="utf-8",
    )

    result = lsl.scan(tmp_path, days=0)
    categories = {candidate["category"] for candidate in result["candidates"]}

    assert {
        "legion-policy-bypass",
        "review-terminal-integrity",
        "validation-environment-drift",
        "worktree-application-lifecycle",
    }.issubset(categories)


def test_jsonl_record_extraction_is_lazy(monkeypatch, tmp_path):
    path = tmp_path / "session.jsonl"
    path.write_text("unused\n", encoding="utf-8")
    consumed = []

    def objects(_path):
        consumed.append("first")
        yield 0, {
            "type": "event_msg",
            "payload": {"type": "agent_message", "message": "first"},
        }
        consumed.append("second")
        yield 1, {
            "type": "event_msg",
            "payload": {"type": "agent_message", "message": "second"},
        }

    monkeypatch.setattr(lsl.legion_session_io, "iter_jsonl_objects", objects)
    records = lsl._extract_records(path)

    assert consumed == []
    assert next(records)["text"] == "first"
    assert consumed == ["first"]


def test_scan_enforces_global_record_budget(tmp_path):
    session = tmp_path / ".codex" / "sessions" / "session.jsonl"
    session.parent.mkdir(parents=True)
    session.write_text(
        "\n".join(
            json.dumps(
                {
                    "type": "event_msg",
                    "payload": {"type": "agent_message", "message": f"record {index}"},
                }
            )
            for index in range(10)
        )
        + "\n",
        encoding="utf-8",
    )

    result = lsl.scan(tmp_path, days=0, session_limit=0, record_limit=3)

    assert result["records_scanned"] == 3
    assert result["record_limit_reached"] is True


def test_record_limit_counts_filtered_tool_objects_before_message_extraction(tmp_path):
    session = tmp_path / ".codex" / "sessions" / "tool-heavy.jsonl"
    session.parent.mkdir(parents=True)
    tool_record = {
        "type": "response_item",
        "payload": {"type": "function_call_output", "output": "ignored"},
    }
    message_record = {
        "type": "event_msg",
        "payload": {
            "type": "user_message",
            "message": "You used the wrong source; verify the authoritative source first.",
        },
    }
    session.write_text(
        "\n".join(json.dumps(item) for item in [tool_record] * 3 + [message_record])
        + "\n",
        encoding="utf-8",
    )

    result = lsl.scan(tmp_path, days=0, session_limit=0, record_limit=3)

    assert result["records_scanned"] == 3
    assert result["record_limit_reached"] is True
    assert result["candidates"] == []


def test_session_discovery_prunes_generated_and_worktree_trees(tmp_path):
    live = tmp_path / ".codex" / "sessions" / "live.jsonl"
    stale = tmp_path / ".codex" / "sessions" / ".legion" / "worktrees" / "stale.jsonl"
    live.parent.mkdir(parents=True)
    stale.parent.mkdir(parents=True)
    live.write_text("{}\n", encoding="utf-8")
    stale.write_text("{}\n", encoding="utf-8")

    files, _skipped = lsl._iter_files(tmp_path, days=0, max_file_mb=0)

    assert live in files
    assert stale not in files
