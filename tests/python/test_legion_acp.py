import importlib.util
import io
import json
import os
import sys

import pytest

HERE = os.path.dirname(__file__)
_SPEC = importlib.util.spec_from_file_location(
    "legion_acp", os.path.join(HERE, "..", "..", "legion-router", "scripts", "legion_acp.py")
)
acp = importlib.util.module_from_spec(_SPEC)
_SPEC.loader.exec_module(acp)


def test_method_names_map_to_the_wire_form():
    assert acp._wire("session_prompt") == "session/prompt"
    assert acp._wire("initialize") == "initialize"


def test_decode_skips_noise_without_dropping_the_session():
    """A banner on stdout is cosmetics; failing on it would be absurd."""
    stream = io.BytesIO(
        b"starting up...\n"
        + acp.encode({"jsonrpc": "2.0", "id": 1, "result": {"ok": True}})
        + b"\n"
        + b'{"not":"jsonrpc"}\n'
    )
    messages = list(acp.decode_stream(stream))
    assert len(messages) == 1
    assert messages[0]["result"] == {"ok": True}


def test_a_client_without_a_permission_handler_is_refused():
    # session/request_permission is a CLIENT method. Declining to implement it
    # means approving everything, which is worse than the adapters this replaces.
    with pytest.raises(acp.AcpError) as excinfo:
        acp.AcpClient(["true"], permission_handler=None)
    assert "permission handler" in str(excinfo.value)


def test_client_rejects_a_method_that_is_not_in_the_protocol():
    client = acp.AcpClient(["true"], permission_handler=lambda params: "allow")
    with pytest.raises(acp.AcpError):
        client.request("session_teleport")


class _FakeProc:
    """An agent that asks for permission before answering, as a real one does."""

    def __init__(self, script):
        self.stdin = io.BytesIO()
        self.stdout = io.BytesIO(script)
        self.stderr = io.BytesIO()
        self.killed = False

    def kill(self):
        self.killed = True

    def wait(self, timeout=None):
        return 0


def test_pump_answers_a_permission_callback_instead_of_deadlocking():
    asked = []

    def handler(params):
        asked.append(params)
        return "allow"

    script = (
        acp.encode({"jsonrpc": "2.0", "id": 99, "method": "session/request_permission",
                    "params": {"toolCall": {"title": "write file"}}})
        + acp.encode({"jsonrpc": "2.0", "id": 1, "result": {"stopReason": "end_turn"}})
    )
    client = acp.AcpClient(["true"], permission_handler=handler)
    client._proc = _FakeProc(script)
    client._next_id = 0

    result = client.request("session_prompt", {"prompt": "hi"})

    assert result == {"stopReason": "end_turn"}
    assert asked and asked[0]["toolCall"]["title"] == "write file"
    replies = [json.loads(line) for line in client._proc.stdin.getvalue().splitlines() if line.strip()]
    granted = [r for r in replies if r.get("id") == 99]
    assert granted and granted[0]["result"]["outcome"]["outcome"] == "allow"


def test_session_updates_reach_the_log_callback():
    seen = []
    script = (
        acp.encode({"jsonrpc": "2.0", "method": "session/update",
                    "params": {"sessionUpdate": "agent_message_chunk", "content": "hello"}})
        + acp.encode({"jsonrpc": "2.0", "id": 1, "result": {}})
    )
    client = acp.AcpClient(["true"], permission_handler=lambda p: "allow",
                           on_update=seen.append)
    client._proc = _FakeProc(script)
    client._next_id = 0
    client.request("session_prompt", {})
    assert seen and seen[0]["sessionUpdate"] == "agent_message_chunk"


def test_update_variants_match_the_session_log_vocabulary():
    """An ACP stream must land in legion.session-event.v2 without translation."""
    sys.path.insert(0, os.path.join(HERE, "..", "..", "legion-observability", "scripts"))
    import legion_session_log as sl

    acp_variants = {
        "user_message", "user_message_chunk", "agent_message", "agent_message_chunk",
        "agent_thought", "agent_thought_chunk", "tool_call_update",
        "tool_call_content_chunk", "terminal_update", "terminal_output_chunk",
        "plan_update", "state_update", "usage_update", "available_commands_update",
        "config_option_update", "session_info_update",
    }
    assert acp_variants <= set(sl.EVENT_TYPES), (
        "the session log must accept every ACP SessionUpdate variant verbatim"
    )


def test_server_refuses_a_method_outside_the_protocol():
    out = io.BytesIO()
    server = acp.AcpAgentServer(lambda m, p: {}, stdin=io.BytesIO(
        acp.encode({"jsonrpc": "2.0", "id": 5, "method": "session/teleport"})
    ), stdout=out)
    server.serve_forever()
    reply = json.loads(out.getvalue().splitlines()[0])
    assert reply["error"]["code"] == -32601


def test_server_reports_a_handler_fault_without_killing_the_session():
    def boom(method, params):
        raise RuntimeError("handler exploded")

    out = io.BytesIO()
    stdin = io.BytesIO(
        acp.encode({"jsonrpc": "2.0", "id": 1, "method": "session/new"})
        + acp.encode({"jsonrpc": "2.0", "id": 2, "method": "session/list"})
    )
    acp.AcpAgentServer(boom, stdin=stdin, stdout=out).serve_forever()
    replies = [json.loads(line) for line in out.getvalue().splitlines()]
    assert len(replies) == 2, "one fault must not end the session"
    assert all(r["error"]["code"] == -32603 for r in replies)


def test_acp_capability_is_declared_and_opt_in():
    """A protocol both sides implement is not one they implement the same way."""
    import importlib.util as _u
    spec = _u.spec_from_file_location(
        "lroute", os.path.join(HERE, "..", "..", "legion-router", "scripts", "legion-route.py")
    )
    route = _u.module_from_spec(spec)
    spec.loader.exec_module(route)

    execs = route.load_executors(
        os.path.join(HERE, "..", "..", "legion-router", "config", "executors.toml")
    )
    assert execs, "the registry must load"
    for name, entry in execs.items():
        assert "acp" in entry, f"{name} must declare whether it can be driven over ACP"
        assert entry["acp"] is False, (
            f"{name} claims ACP before being exercised over it; the bespoke adapter "
            f"stays authoritative until then"
        )
