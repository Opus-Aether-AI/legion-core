import importlib.util
import json
import os
import sys

import pytest

HERE = os.path.dirname(__file__)
sys.path.insert(0, os.path.join(HERE, "..", "..", "legion-observability", "scripts"))
import legion_session_log as sl  # noqa: E402


def test_appends_in_order_and_numbers_monotonically(tmp_path):
    log = sl.SessionLog(str(tmp_path), "s1")
    log.append("turn_start")
    log.append("user_message", "do the thing")
    log.append("turn_end")
    events = list(sl.read_events(log.path))
    assert [e["sequence"] for e in events] == [0, 1, 2]
    assert [e["type"] for e in events] == ["turn_start", "user_message", "turn_end"]


def test_resumes_numbering_instead_of_restarting(tmp_path):
    """Two writers restarting at 0 would make the append order unrecoverable."""
    first = sl.SessionLog(str(tmp_path), "s2")
    first.append("user_message", "one")
    second = sl.SessionLog(str(tmp_path), "s2")
    second.append("user_message", "two")
    assert [e["sequence"] for e in sl.read_events(first.path)] == [0, 1]


def test_content_is_stored_in_full_not_excerpted(tmp_path):
    """v1's excerpt is exactly what made the old log unusable as evidence."""
    log = sl.SessionLog(str(tmp_path), "s3")
    big = "x" * 20000
    log.append("user_message", big)
    stored = list(sl.read_events(log.path))[0]
    assert stored["content"] == big


def test_redaction_is_flagged_not_silent(tmp_path):
    log = sl.SessionLog(str(tmp_path), "s4")
    event = log.append("user_message", "token sk-abcdefghijklmnopqrstuvwx here")
    assert event["redacted"] is True
    assert "sk-abcdefghij" not in json.dumps(event)
    plain = log.append("user_message", "nothing secret")
    assert plain["redacted"] is False


def test_unknown_event_type_is_refused(tmp_path):
    log = sl.SessionLog(str(tmp_path), "s5")
    with pytest.raises(sl.SessionLogError):
        log.append("invented_event", "x")


def test_derive_model_history_keeps_only_model_visible_events(tmp_path):
    log = sl.SessionLog(str(tmp_path), "s6")
    log.append("turn_start")
    log.append("user_message", "visible")
    log.append("usage_update", {"tokens": 5})
    history = sl.derive_model_history(sl.read_events(log.path))
    assert [h["content"] for h in history] == ["visible"]


def test_invariant_passes_when_the_log_reproduces_the_request(tmp_path):
    log = sl.SessionLog(str(tmp_path), "s7")
    log.append("user_message", "a")
    log.append("agent_message", "b")
    sent = sl.derive_model_history(sl.read_events(log.path))
    sl.assert_model_visible_is_logged(sent, log.path)


def test_invariant_fails_when_something_reached_the_model_unlogged(tmp_path):
    """The failure this exists to catch is invisible by construction otherwise."""
    log = sl.SessionLog(str(tmp_path), "s8")
    log.append("user_message", "logged")
    sent = sl.derive_model_history(sl.read_events(log.path))
    sent.append({"type": "user_message", "content": "never logged", "sequence": 99, "redacted": False})
    with pytest.raises(sl.SessionLogError):
        sl.assert_model_visible_is_logged(sent, log.path)


def test_a_truncated_final_line_does_not_destroy_the_session(tmp_path):
    log = sl.SessionLog(str(tmp_path), "s9")
    log.append("user_message", "kept")
    with open(log.path, "a", encoding="utf-8") as handle:
        handle.write('{"schema": "legion.session-event')  # crash mid-append
    events = list(sl.read_events(log.path))
    assert len(events) == 1
    assert events[0]["content"] == "kept"


def test_vocabulary_matches_the_schema_enum():
    """Writer and schema must not drift; that is why the list has one home."""
    path = os.path.join(HERE, "..", "..", "legion-observability", "schema",
                        "legion.session-event.v2.schema.json")
    with open(path, encoding="utf-8") as handle:
        schema = json.load(handle)
    assert set(schema["properties"]["type"]["enum"]) == set(sl.EVENT_TYPES)
