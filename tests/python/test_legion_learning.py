import importlib.util
import json
import os
import subprocess
import sys

HERE = os.path.dirname(__file__)
SCRIPT = os.path.join(
    HERE, "..", "..", "legion-observability", "scripts", "legion_learning.py"
)
SPEC = importlib.util.spec_from_file_location("legion_learning", SCRIPT)
learning = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = learning
SPEC.loader.exec_module(learning)


def _session(path, messages):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(
        "".join(json.dumps(message) + "\n" for message in messages),
        encoding="utf-8",
    )
    return path


def test_repo_file_scan_prunes_generated_and_nested_worktree_trees(
    tmp_path, monkeypatch
):
    keep = tmp_path / "src" / "keep.py"
    generated = tmp_path / "node_modules" / "package" / "ignored.js"
    nested_worktree = tmp_path / ".claude" / "worktrees" / "old" / "ignored.py"
    for path in (keep, generated, nested_worktree):
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text("content", encoding="utf-8")

    real_walk = learning.legion_session_io.os.walk
    visited = []

    def tracking_walk(*args, **kwargs):
        for current, dirs, files in real_walk(*args, **kwargs):
            visited.append(os.path.relpath(current, tmp_path))
            yield current, dirs, files

    monkeypatch.setattr(learning.legion_session_io.os, "walk", tracking_walk)

    scanned = learning._repo_files(str(tmp_path))

    assert scanned == [keep]
    assert not any(path.startswith("node_modules") for path in visited)
    assert not any(path.startswith(os.path.join(".claude", "worktrees")) for path in visited)


def test_redact_text_is_fail_closed_for_credentials_identity_and_paths():
    raw = (
        "email me at dev@example.com using ghp_abcdefghijklmnopqrstuvwxyz123456 "
        "Bearer abc.def.ghi from /Users/alice/private/repo/file.py"
    )

    redacted = learning.redact_text(raw)

    assert "dev@example.com" not in redacted
    assert "ghp_" not in redacted
    assert "abc.def.ghi" not in redacted
    assert "/Users/alice" not in redacted
    assert "[email]" in redacted
    assert "[credential]" in redacted
    assert "[path]" in redacted


def test_redact_text_removes_slack_pem_and_non_home_absolute_paths():
    slack_token = "xox" + "b-" + "123456789012-123456789012-SyntheticTokenValue"
    raw = (
        f"Slack {slack_token} "
        "-----BEGIN PRIVATE KEY-----\n"
        "cHJpdmF0ZS1rZXktbWF0ZXJpYWw=\n"
        "-----END PRIVATE KEY----- "
        "from /var/lib/legion/private/config.json and C:\\ProgramData\\Legion\\secret.txt "
        "while retaining https://example.com/docs"
    )

    redacted = learning.redact_text(raw)

    assert slack_token not in redacted
    assert "PRIVATE KEY" not in redacted
    assert "cHJpdmF0ZS1rZXktbWF0ZXJpYWw" not in redacted
    assert "/var/lib/legion" not in redacted
    assert "C:\\ProgramData\\Legion" not in redacted
    assert "[credential]" in redacted
    assert "[private-key]" in redacted
    assert "[path]" in redacted


def test_redact_text_preserves_urls_and_single_segment_slash_commands():
    raw = "Run /ultra-review and inspect https://example.com/docs/review."

    redacted = learning.redact_text(raw)

    assert "/ultra-review" in redacted
    assert "https://example.com/docs/review" in redacted


def test_redact_text_removes_local_file_urls():
    redacted = learning.redact_text(
        "Inspect file:///Users/alice/private/secret.txt before sharing."
    )

    assert "alice" not in redacted
    assert "private/secret" not in redacted
    assert "file://[path]" in redacted


def test_normalize_session_preserves_roles_and_hashes_dispatch_prompts(tmp_path):
    session = _session(
        tmp_path / ".codex" / "sessions" / "webapp.jsonl",
        [
            {
                "type": "event_msg",
                "timestamp": "2026-08-05T09:00:00Z",
                "payload": {
                    "type": "user_message",
                    "message": "Use Plane, not Linear. That's the wrong source.",
                },
            },
            {
                "message": {
                    "role": "assistant",
                    "content": [
                        {
                            "type": "tool_use",
                            "name": "Agent",
                            "input": {"prompt": "audit /Users/alice/secret.py"},
                        }
                    ],
                }
            },
        ],
    )

    normalized = learning.normalize_session_file(session, home=tmp_path)

    assert normalized[0]["role"] == "user"
    assert normalized[0]["source"] == "codex"
    assert normalized[1]["event_type"] == "dispatch"
    assert normalized[1]["dispatch_hash"]
    serialized = json.dumps(normalized)
    assert "audit /Users/alice/secret.py" not in serialized
    assert "/Users/alice" not in serialized


def test_normalize_session_records_top_level_codex_spawn_dispatch(tmp_path):
    session = _session(
        tmp_path / ".codex" / "sessions" / "repo" / "run.jsonl",
        [
            {
                "type": "response_item",
                "timestamp": "2026-08-05T09:00:00Z",
                "payload": {
                    "type": "function_call",
                    "name": "spawn_agent",
                    "arguments": json.dumps(
                        {
                            "task_name": "audit",
                            "message": "Audit /var/lib/legion/private/config.json",
                        }
                    ),
                    "call_id": "call-1",
                },
            }
        ],
    )

    normalized = learning.normalize_session_file(session, home=tmp_path)

    assert len(normalized) == 1
    assert normalized[0]["role"] == "assistant"
    assert normalized[0]["event_type"] == "dispatch"
    assert normalized[0]["excerpt"] == "spawn_agent dispatch"
    assert normalized[0]["dispatch_hash"]
    assert "private/config" not in json.dumps(normalized)


def test_normalize_session_uses_session_cwd_for_project_attribution(tmp_path):
    repo = tmp_path / "Hackerman" / "webapp"
    repo.mkdir(parents=True)
    session = _session(
        tmp_path / ".codex" / "sessions" / "2026" / "08" / "05" / "run.jsonl",
        [
            {
                "type": "session_meta",
                "payload": {"cwd": str(repo)},
            },
            {
                "type": "event_msg",
                "payload": {"type": "user_message", "message": "Audit all references."},
            },
        ],
    )

    normalized = learning.normalize_session_file(session, home=tmp_path)

    expected = f"local:{learning.legion_state.repository_project_id(str(repo))}"
    assert normalized[0]["project"] == expected


def test_analyze_session_links_correction_to_verified_outcome_and_scores_axes(tmp_path):
    session = _session(
        tmp_path / ".codex" / "sessions" / "webapp.jsonl",
        [
            {
                "type": "event_msg",
                "timestamp": "2026-08-05T09:00:00Z",
                "payload": {
                    "type": "user_message",
                    "message": "Use Plane, not Linear. That's the wrong source of truth.",
                },
            },
            {
                "type": "event_msg",
                "timestamp": "2026-08-05T09:02:00Z",
                "payload": {
                    "type": "agent_message",
                    "message": "Switched the ticket integration to Plane and added tests.",
                },
            },
            {
                "type": "event_msg",
                "timestamp": "2026-08-05T09:03:00Z",
                "payload": {
                    "type": "agent_message",
                    "message": "Validation complete: 14 tests passed and production workflow verified.",
                },
            },
        ],
    )
    events = learning.normalize_session_file(session, home=tmp_path)

    report = learning.analyze_events(events, repo=str(tmp_path), project="webapp")

    assert report["schema"] == "legion.learning.report.v2"
    assert report["sessions"][0]["schema"] == "legion.session-summary.v1"
    assert report["decisions"][0]["law_key"] == "source-of-truth"
    assert report["outcome_links"][0]["decision_id"] == report["decisions"][0]["id"]
    assert report["outcome_links"][0]["status"] == "verified"
    assert set(report["behavior_scores"]) == {
        "execution_leverage",
        "steering",
        "engineering_quality",
        "product_thinking",
        "planning",
    }
    assert len(report["code_quality"]) == 14
    assert report["evidence_coverage"]["linked_decisions"] == 1
    assert str(tmp_path) not in json.dumps(report)


def test_outcome_link_uses_latest_execution_evidence(tmp_path):
    session = _session(
        tmp_path / ".codex" / "sessions" / "repo" / "run.jsonl",
        [
            {"payload": {"type": "user_message", "message": "Audit all references."}},
            {"payload": {"type": "agent_message", "message": "Tests passed."}},
            {"payload": {"type": "agent_message", "message": "Validation failed with a regression."}},
        ],
    )
    report = learning.analyze_events(
        learning.normalize_session_file(session, home=tmp_path),
        repo=str(tmp_path),
        project="repo",
    )

    assert report["outcome_links"][0]["status"] == "failed"
    assert "failed" in report["outcome_links"][0]["evidence_excerpt"].lower()
    assert report["episodes"][0]["outcome_status"] == "failed"


def test_outcome_link_inverts_negated_execution_evidence(tmp_path):
    examples = [
        ("Tests did not pass.", "failed"),
        ("Validation did not fail.", "verified"),
    ]
    for index, (evidence, expected) in enumerate(examples):
        session = _session(
            tmp_path / ".codex" / "sessions" / "repo" / f"{index}.jsonl",
            [
                {"payload": {"type": "user_message", "message": "Audit all references."}},
                {"payload": {"type": "agent_message", "message": evidence}},
            ],
        )
        report = learning.analyze_events(
            learning.normalize_session_file(session, home=tmp_path),
            repo=str(tmp_path),
            project="repo",
        )

        assert report["outcome_links"][0]["status"] == expected
        assert report["episodes"][0]["outcome_status"] == expected


def test_outcome_link_scopes_negation_to_each_execution_cue(tmp_path):
    examples = [
        ("Tests did not pass but later passed.", "verified"),
        ("Tests not only passed; they exceeded the quality bar.", "verified"),
    ]
    for index, (evidence, expected) in enumerate(examples):
        session = _session(
            tmp_path / ".codex" / "sessions" / "repo" / f"scoped-{index}.jsonl",
            [
                {"payload": {"type": "user_message", "message": "Audit all references."}},
                {"payload": {"type": "agent_message", "message": evidence}},
            ],
        )
        report = learning.analyze_events(
            learning.normalize_session_file(session, home=tmp_path),
            repo=str(tmp_path),
            project="repo",
        )

        assert report["outcome_links"][0]["status"] == expected
        assert report["episodes"][0]["outcome_status"] == expected


def test_webapp_feedback_laws_are_classified_independently():
    examples = {
        "Use Plane, not Linear. That's the wrong source.": "source-of-truth",
        "You are Codex, not Claude; configure the right client.": "harness-identity",
        "Actually test it with Hermes e2e before updating the page.": "test-real-workflow",
        "Self-heal keeps chasing stale superseded runs.": "stale-automation",
        "The right panel is trash; inspect the live UI.": "visible-acceptance",
        "Centralize the model defaults in one configuration file.": "centralize-configuration",
    }

    for text, law in examples.items():
        assert learning.classify_decision_law(text)[0] == law


def test_promote_laws_requires_cross_project_recurrence():
    reports = [
        {
            "project": "one",
            "decisions": [
                {"id": "d1", "episode_id": "e1", "law_key": "audit-completeness"},
                {"id": "d2", "episode_id": "e2", "law_key": "audit-completeness"},
            ],
        },
        {
            "project": "two",
            "decisions": [
                {"id": "d3", "episode_id": "e3", "law_key": "audit-completeness"},
                {"id": "d4", "episode_id": "e4", "law_key": "visible-acceptance"},
            ],
        },
    ]

    laws = learning.promote_laws(reports, min_episodes=3, min_projects=2)

    assert [law["key"] for law in laws] == ["audit-completeness"]
    assert laws[0]["schema"] == "legion.learning-law.v1"
    assert laws[0]["status"] == "active"
    assert laws[0]["support"]["episodes"] == 3
    assert laws[0]["guidance"]
    assert laws[0]["validation"]


def test_merge_law_store_is_idempotent_and_keeps_stronger_support(tmp_path):
    path = tmp_path / "laws.json"
    law = {
        "schema": "legion.learning-law.v1",
        "key": "audit-completeness",
        "status": "active",
        "confidence": 0.8,
        "support": {"episodes": 3, "projects": 2},
        "evidence_ids": ["d1", "d2", "d3"],
    }

    learning.merge_law_store(path, [law])
    learning.merge_law_store(path, [law])

    payload = json.loads(path.read_text(encoding="utf-8"))
    assert payload["schema"] == "legion.learning-laws.v1"
    assert len(payload["laws"]) == 1
    assert payload["laws"][0]["support"] == {"episodes": 3, "projects": 2}


def test_merge_law_store_retires_laws_no_longer_supported(tmp_path):
    path = tmp_path / "laws.json"
    law = {
        "schema": "legion.learning-law.v1",
        "key": "stale-automation",
        "status": "active",
        "confidence": 0.8,
        "support": {"episodes": 3, "projects": 2},
        "evidence_ids": ["d1", "d2", "d3"],
        "guidance": "Ignore stale runs.",
        "validation": "Replay stale fixtures.",
    }
    learning.merge_law_store(path, [law])

    payload = learning.merge_law_store(path, [])

    assert payload["laws"][0]["status"] == "retired"
    assert payload["laws"][0]["retired_at"]


def test_merge_law_store_replaces_active_law_with_current_support(tmp_path):
    path = tmp_path / "laws.json"
    previous = {
        "schema": learning.LAW_SCHEMA,
        "key": "audit-completeness",
        "status": "active",
        "confidence": 0.95,
        "support": {"episodes": 8, "projects": 4},
        "evidence_ids": ["old"],
        "guidance": "Use stale support.",
        "validation": "Replay stale evidence.",
    }
    current = {
        **previous,
        "confidence": 0.84,
        "support": {"episodes": 3, "projects": 2},
        "evidence_ids": ["current"],
        "guidance": "Use current support.",
    }
    learning.merge_law_store(path, [previous])

    payload = learning.merge_law_store(path, [current])

    assert payload["laws"][0]["support"] == {"episodes": 3, "projects": 2}
    assert payload["laws"][0]["evidence_ids"] == ["current"]
    assert payload["laws"][0]["guidance"] == "Use current support."


def test_filter_events_for_repo_keeps_only_matching_project(tmp_path):
    repo = tmp_path / "webapp"
    repo.mkdir()
    project = f"local:{learning.legion_state.repository_project_id(str(repo))}"
    events = [
        {"id": "one", "project": project},
        {"id": "two", "project": "other"},
    ]

    assert learning.filter_events_for_repo(events, str(repo)) == [events[0]]


def test_repo_only_distinguishes_remotes_with_the_same_basename(tmp_path):
    repos = []
    events = []
    for owner in ("alpha", "beta"):
        repo = tmp_path / owner / "shared"
        repo.mkdir(parents=True)
        subprocess.run(["git", "init", "-q", str(repo)], check=True)
        subprocess.run(
            [
                "git",
                "-C",
                str(repo),
                "remote",
                "add",
                "origin",
                f"https://github.com/{owner}/shared.git",
            ],
            check=True,
        )
        session = _session(
            tmp_path / ".codex" / "sessions" / owner / "run.jsonl",
            [
                {"type": "session_meta", "payload": {"cwd": str(repo)}},
                {
                    "type": "event_msg",
                    "payload": {
                        "type": "user_message",
                        "message": f"Audit all {owner} references.",
                    },
                },
            ],
        )
        repos.append(repo)
        events.extend(learning.normalize_session_file(session, home=tmp_path))

    filtered = learning.filter_events_for_repo(events, str(repos[0]))

    assert {event["project"] for event in filtered} == {"github.com/alpha/shared"}
    assert all("alpha" in event["excerpt"] for event in filtered)


def test_repo_only_distinguishes_local_repositories_with_the_same_basename(tmp_path):
    repos = []
    events = []
    for owner in ("alpha", "beta"):
        repo = tmp_path / owner / "shared"
        repo.mkdir(parents=True)
        session = _session(
            tmp_path / ".codex" / "sessions" / f"local-{owner}" / "run.jsonl",
            [
                {"type": "session_meta", "payload": {"cwd": str(repo)}},
                {
                    "type": "event_msg",
                    "payload": {
                        "type": "user_message",
                        "message": f"Audit all local {owner} references.",
                    },
                },
            ],
        )
        repos.append(repo)
        events.extend(learning.normalize_session_file(session, home=tmp_path))

    filtered = learning.filter_events_for_repo(events, str(repos[0]))

    assert len(filtered) == 1
    assert filtered[0]["project"].startswith("local:shared-")
    assert "alpha" in filtered[0]["excerpt"]


def test_project_component_cannot_escape_learning_state():
    assert learning.safe_project_component("../../My Project") == "my-project"


def test_session_file_scan_honors_size_cap(tmp_path):
    path = tmp_path / ".codex" / "sessions" / "large.jsonl"
    path.parent.mkdir(parents=True)
    path.write_text("x" * 2048, encoding="utf-8")

    assert learning._iter_session_files(tmp_path, 0, 0.001) == []


def test_session_file_scan_honors_deterministic_aggregate_caps(tmp_path):
    paths = []
    for index in range(3):
        path = tmp_path / ".codex" / "sessions" / f"{index}.jsonl"
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text("x" * 100, encoding="utf-8")
        os.utime(path, (100 + index, 100 + index))
        paths.append(path)

    file_limited = learning._iter_session_files(
        tmp_path,
        0,
        0,
        max_files=2,
        max_total_mb=0,
    )
    byte_limited = learning._iter_session_files(
        tmp_path,
        0,
        0,
        max_files=0,
        max_total_mb=0.00015,
    )

    assert file_limited == [paths[2], paths[1]]
    assert byte_limited == [paths[2]]


def test_cli_analyze_writes_redacted_project_report_and_global_laws(tmp_path):
    home = tmp_path / "home"
    repo = tmp_path / "repo"
    state = tmp_path / "state"
    repo.mkdir()
    for idx, project in enumerate(("one", "one", "two"), start=1):
        _session(
            home / ".codex" / "sessions" / project / f"{idx}.jsonl",
            [
                {
                    "type": "event_msg",
                    "timestamp": f"2026-08-0{idx}T09:00:00Z",
                    "payload": {
                        "type": "user_message",
                        "message": (
                            "Audit all references before shipping. "
                            "Token ghp_abcdefghijklmnopqrstuvwxyz123456"
                        ),
                    },
                }
            ],
        )

    proc = subprocess.run(
        [
            sys.executable,
            SCRIPT,
            "analyze",
            "--home",
            str(home),
            "--repo",
            str(repo),
            "--state-root",
            str(state),
            "--json",
        ],
        text=True,
        capture_output=True,
        check=False,
    )

    assert proc.returncode == 0, proc.stderr
    payload = json.loads(proc.stdout)
    report_path = payload["report_path"]
    laws_path = payload["laws_path"]
    assert os.path.exists(report_path)
    assert os.path.exists(laws_path)
    with open(report_path, encoding="utf-8") as handle:
        serialized = handle.read()
    assert "ghp_" not in serialized
    assert json.loads(serialized)["schema"] == "legion.learning.report.v2"


def test_cli_analyze_honors_aggregate_event_cap(tmp_path):
    home = tmp_path / "home"
    repo = tmp_path / "repo"
    state = tmp_path / "state"
    repo.mkdir()
    for index in range(2):
        _session(
            home / ".codex" / "sessions" / "repo" / f"{index}.jsonl",
            [
                {
                    "type": "event_msg",
                    "payload": {
                        "type": "user_message",
                        "message": f"Audit all references for event {event}.",
                    },
                }
                for event in range(5)
            ],
        )

    proc = subprocess.run(
        [
            sys.executable,
            SCRIPT,
            "analyze",
            "--home",
            str(home),
            "--repo",
            str(repo),
            "--state-root",
            str(state),
            "--lookback-days",
            "0",
            "--max-files",
            "2",
            "--max-total-mb",
            "1",
            "--max-events",
            "3",
            "--json",
        ],
        text=True,
        capture_output=True,
        check=False,
    )

    assert proc.returncode == 0, proc.stderr
    payload = json.loads(proc.stdout)
    assert payload["files_scanned"] == 1
    assert payload["events_processed"] == 3


def test_cli_repo_only_applies_event_cap_after_repository_filter(tmp_path):
    home = tmp_path / "home"
    state = tmp_path / "state"
    target_repo = tmp_path / "target" / "shared"
    other_repo = tmp_path / "other" / "shared"
    for owner, repo in (("target", target_repo), ("other", other_repo)):
        repo.mkdir(parents=True)
        subprocess.run(["git", "init", "-q", str(repo)], check=True)
        subprocess.run(
            [
                "git",
                "-C",
                str(repo),
                "remote",
                "add",
                "origin",
                f"https://github.com/example/{owner}.git",
            ],
            check=True,
        )

    target_session = _session(
        home / ".codex" / "sessions" / "target.jsonl",
        [
            {"type": "session_meta", "payload": {"cwd": str(target_repo)}},
            {
                "type": "event_msg",
                "payload": {
                    "type": "user_message",
                    "message": "Audit all target references.",
                },
            },
        ],
    )
    other_session = _session(
        home / ".codex" / "sessions" / "other.jsonl",
        [
            {"type": "session_meta", "payload": {"cwd": str(other_repo)}},
            {
                "type": "event_msg",
                "payload": {
                    "type": "user_message",
                    "message": "Audit all unrelated references.",
                },
            },
        ],
    )
    os.utime(target_session, (100, 100))
    os.utime(other_session, (200, 200))

    proc = subprocess.run(
        [
            sys.executable,
            SCRIPT,
            "analyze",
            "--home",
            str(home),
            "--repo",
            str(target_repo),
            "--state-root",
            str(state),
            "--repo-only",
            "--lookback-days",
            "0",
            "--max-files",
            "2",
            "--max-total-mb",
            "1",
            "--max-events",
            "1",
            "--json",
        ],
        text=True,
        capture_output=True,
        check=False,
    )

    assert proc.returncode == 0, proc.stderr
    payload = json.loads(proc.stdout)
    assert payload["events_processed"] == 1
    assert payload["sessions"] == 1


def test_cli_repo_only_applies_file_cap_to_matching_sessions(tmp_path):
    home = tmp_path / "home"
    state = tmp_path / "state"
    target_repo = tmp_path / "target"
    other_repo = tmp_path / "other"
    for name, repo in (("target", target_repo), ("other", other_repo)):
        repo.mkdir()
        subprocess.run(["git", "init", "-q", str(repo)], check=True)
        subprocess.run(
            [
                "git",
                "-C",
                str(repo),
                "remote",
                "add",
                "origin",
                f"https://github.com/example/{name}.git",
            ],
            check=True,
        )

    target_session = _session(
        home / ".codex" / "sessions" / "target.jsonl",
        [
            {"type": "session_meta", "payload": {"cwd": str(target_repo)}},
            {
                "type": "event_msg",
                "payload": {
                    "type": "user_message",
                    "message": "Audit all target references.",
                },
            },
        ],
    )
    os.utime(target_session, (100, 100))
    for index in range(100):
        session = _session(
            home / ".codex" / "sessions" / f"other-{index}.jsonl",
            [
                {"type": "session_meta", "payload": {"cwd": str(other_repo)}},
                {
                    "type": "event_msg",
                    "payload": {
                        "type": "user_message",
                        "message": f"Audit unrelated references {index}.",
                    },
                },
            ],
        )
        os.utime(session, (200 + index, 200 + index))

    proc = subprocess.run(
        [
            sys.executable,
            SCRIPT,
            "analyze",
            "--home",
            str(home),
            "--repo",
            str(target_repo),
            "--state-root",
            str(state),
            "--repo-only",
            "--lookback-days",
            "0",
            "--max-files",
            "100",
            "--max-total-mb",
            "1",
            "--max-events",
            "1000",
            "--json",
        ],
        text=True,
        capture_output=True,
        check=False,
    )

    assert proc.returncode == 0, proc.stderr
    payload = json.loads(proc.stdout)
    assert payload["events_processed"] == 1
    assert payload["sessions"] == 1


def test_latest_repository_reports_ignore_unattributed_legacy_local_snapshots(
    tmp_path,
):
    reports = tmp_path / "reports"
    reports.mkdir()
    legacy = {
        "schema": learning.REPORT_SCHEMA,
        "generated_at": "2026-01-01T00:00:00Z",
        "repo": "[local-repo]",
        "decisions": [
            {"id": "old", "episode_id": "old", "law_key": "audit-completeness"},
        ],
    }
    current = {
        "schema": learning.REPORT_SCHEMA,
        "generated_at": "2026-08-05T00:00:00Z",
        "repo": "local:repo-current",
        "decisions": [],
    }
    (reports / "legacy.json").write_text(json.dumps(legacy), encoding="utf-8")

    selected = learning._latest_repository_reports(reports, current)

    assert selected == [current]


def test_cli_analyze_promotes_from_only_latest_snapshot_per_repository(tmp_path):
    home = tmp_path / "home"
    repo = tmp_path / "repo"
    state = tmp_path / "state"
    global_learning = state / "global" / "learning"
    snapshots = global_learning / "project-reports"
    repo.mkdir()
    subprocess.run(["git", "init", "-q", str(repo)], check=True)
    subprocess.run(
        [
            "git",
            "-C",
            str(repo),
            "remote",
            "add",
            "origin",
            "https://github.com/example/current.git",
        ],
        check=True,
    )
    snapshots.mkdir(parents=True)

    stale_local = {
        "schema": learning.REPORT_SCHEMA,
        "generated_at": "2026-01-01T00:00:00Z",
        "repo": "github.com/example/current",
        "project": "one",
        "decisions": [
            {"id": "d1", "episode_id": "e1", "law_key": "audit-completeness"},
            {"id": "d2", "episode_id": "e2", "law_key": "audit-completeness"},
        ],
    }
    other_repo = {
        "schema": learning.REPORT_SCHEMA,
        "generated_at": "2026-01-02T00:00:00Z",
        "repo": "github.com/example/other",
        "project": "two",
        "decisions": [
            {"id": "d3", "episode_id": "e3", "law_key": "audit-completeness"},
        ],
    }
    (snapshots / "local-old.json").write_text(json.dumps(stale_local), encoding="utf-8")
    (snapshots / "other.json").write_text(json.dumps(other_repo), encoding="utf-8")
    (global_learning / "laws.json").write_text(
        json.dumps(
            {
                "schema": "legion.learning-laws.v1",
                "laws": [
                    {
                        "schema": learning.LAW_SCHEMA,
                        "key": "audit-completeness",
                        "status": "active",
                        "confidence": 0.84,
                        "support": {"episodes": 3, "projects": 2},
                        "evidence_ids": ["d1", "d2", "d3"],
                    }
                ],
            }
        ),
        encoding="utf-8",
    )

    proc = subprocess.run(
        [
            sys.executable,
            SCRIPT,
            "analyze",
            "--home",
            str(home),
            "--repo",
            str(repo),
            "--state-root",
            str(state),
            "--lookback-days",
            "0",
            "--json",
        ],
        text=True,
        capture_output=True,
        check=False,
    )

    assert proc.returncode == 0, proc.stderr
    laws = json.loads((global_learning / "laws.json").read_text(encoding="utf-8"))
    audit_law = next(law for law in laws["laws"] if law["key"] == "audit-completeness")
    assert audit_law["status"] == "retired"


def test_learning_schemas_are_versioned_valid_json():
    schema_dir = os.path.join(
        HERE, "..", "..", "legion-observability", "schema"
    )
    expected = {
        "legion.session-event.v1.schema.json": "legion.session-event.v1",
        "legion.session-summary.v1.schema.json": "legion.session-summary.v1",
        "legion.episode.v1.schema.json": "legion.episode.v1",
        "legion.decision.v1.schema.json": "legion.decision.v1",
        "legion.outcome-link.v1.schema.json": "legion.outcome-link.v1",
        "legion.learning-law.v1.schema.json": "legion.learning-law.v1",
        "legion.learning.report.v2.schema.json": "legion.learning.report.v2",
    }

    for filename, title in expected.items():
        with open(os.path.join(schema_dir, filename), encoding="utf-8") as handle:
            schema = json.load(handle)
        assert schema["$schema"] == "https://json-schema.org/draft/2020-12/schema"
        assert schema["title"] == title


def test_redact_payload_recurses_without_corrupting_json():
    payload = {
        "nested": [
            {"connection": "postgres://user:secret@db.example/app"},
            "email dev@example.com",
        ],
        "count": 2,
    }

    redacted = learning.redact_payload(payload)

    assert redacted["count"] == 2
    assert redacted["nested"][0]["connection"] == "[credential-url]"
    assert "dev@example.com" not in redacted["nested"][1]
    json.dumps(redacted)


def test_v2_session_discovery_prunes_generated_and_worktree_trees(tmp_path):
    live = tmp_path / ".codex" / "sessions" / "live.jsonl"
    stale = tmp_path / ".codex" / "sessions" / ".legion" / "worktrees" / "stale.jsonl"
    live.parent.mkdir(parents=True)
    stale.parent.mkdir(parents=True)
    live.write_text("{}\n", encoding="utf-8")
    stale.write_text("{}\n", encoding="utf-8")

    files = learning._iter_session_files(
        tmp_path, lookback_days=0, max_file_mb=0
    )

    assert live in files
    assert stale not in files


def test_normalization_stops_at_event_budget(tmp_path):
    session = tmp_path / "session.jsonl"
    session.write_text(
        "\n".join(
            json.dumps(
                {
                    "type": "user",
                    "message": {"role": "user", "content": str(index)},
                }
            )
            for index in range(10)
        )
        + "\n",
        encoding="utf-8",
    )

    events = learning.normalize_session_file(session, home=tmp_path, max_events=3)

    assert len(events) == 3


def _self_learn():
    import importlib.util, os
    here = os.path.dirname(__file__)
    path = os.path.join(here, "..", "..", "legion-observability", "scripts", "legion-self-learn.py")
    spec = importlib.util.spec_from_file_location("sl_mem", path)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


def test_absent_memory_still_initialises(tmp_path):
    sl = _self_learn()
    memory = sl.load_memory(str(tmp_path))
    assert memory.get("schema") == sl.MEMORY_SCHEMA


def test_corrupt_memory_raises_instead_of_reading_as_empty(tmp_path):
    """Fail closed: treating corruption as empty let the next apply erase it."""
    sl = _self_learn()
    target = sl.memory_path(str(tmp_path))
    os.makedirs(os.path.dirname(target), exist_ok=True)
    with open(target, "w", encoding="utf-8") as handle:
        handle.write('{"schema": "legion.harness-memory', )  # truncated mid-write

    try:
        sl.load_memory(str(tmp_path))
    except sl.CorruptMemoryError as exc:
        assert "refusing to overwrite" in str(exc)
    else:
        raise AssertionError("corrupt memory was read as empty instead of raising")


def test_corrupt_memory_is_quarantined_not_deleted_on_explicit_reset(tmp_path):
    sl = _self_learn()
    target = sl.memory_path(str(tmp_path))
    os.makedirs(os.path.dirname(target), exist_ok=True)
    original = '{"schema": "wrong", "entities": {"a": 1}}'
    with open(target, "w", encoding="utf-8") as handle:
        handle.write(original)

    memory = sl.load_memory(str(tmp_path), allow_corrupt_reset=True)

    assert memory.get("schema") == sl.MEMORY_SCHEMA
    quarantined = sl.memory_quarantine_path(str(tmp_path))
    assert os.path.exists(quarantined), "the operator asked to move on, not to lose evidence"
    with open(quarantined, encoding="utf-8") as handle:
        assert handle.read() == original


def test_hints_reports_corruption_rather_than_an_empty_store(tmp_path):
    """"no hints" and "hints unreadable" lead a caller to opposite conclusions."""
    sl = _self_learn()
    target = sl.memory_path(str(tmp_path))
    os.makedirs(os.path.dirname(target), exist_ok=True)
    with open(target, "w", encoding="utf-8") as handle:
        handle.write("not json at all")

    result = sl.hints(str(tmp_path))

    assert result.get("memory_status") == "corrupt"
    assert result.get("entities") == {}
    assert "refusing to overwrite" in result.get("error", "")
