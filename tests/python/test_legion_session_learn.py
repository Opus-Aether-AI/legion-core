import importlib.util
import json
import os
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

    result = lsl.scan(tmp_path, days=1, queries=["moneyball"])
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

    result = lsl.scan(tmp_path, days=1, queries=["harness-bench"])
    categories = {candidate["category"]: candidate for candidate in result["candidates"]}

    assert "user-correction-feedback" in categories
    correction = categories["user-correction-feedback"]
    assert correction["entity"] == "plugin:legion-observability"
    assert correction["evidence"][0]["role"] == "user"
    assert "svineet/harness-bench" in correction["evidence"][0]["snippet"]


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
