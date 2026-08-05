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

    assert normalized[0]["project"] == "webapp"


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


def test_filter_events_for_repo_keeps_only_matching_project(tmp_path):
    repo = tmp_path / "webapp"
    repo.mkdir()
    events = [
        {"id": "one", "project": "webapp"},
        {"id": "two", "project": "other"},
    ]

    assert learning.filter_events_for_repo(events, str(repo)) == [events[0]]


def test_project_component_cannot_escape_learning_state():
    assert learning.safe_project_component("../../My Project") == "my-project"


def test_session_file_scan_honors_size_cap(tmp_path):
    path = tmp_path / ".codex" / "sessions" / "large.jsonl"
    path.parent.mkdir(parents=True)
    path.write_text("x" * 2048, encoding="utf-8")

    assert learning._iter_session_files(tmp_path, 0, 0.001) == []


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
