import importlib.util
import io
import json
import os
import subprocess
import sys
import threading
import time

import pytest

HERE = os.path.dirname(__file__)
_SPEC = importlib.util.spec_from_file_location(
    "legion_acp", os.path.join(HERE, "..", "..", "legion-router", "scripts", "legion_acp.py")
)
acp = importlib.util.module_from_spec(_SPEC)
_SPEC.loader.exec_module(acp)


# ── wire names ───────────────────────────────────────────────────────────

def test_wire_names_are_taken_from_the_schema_not_derived():
    # v1 and v2 disagree (v1: authenticate / session/load / session/set_mode).
    # Deriving from Python identifiers works for some names by luck and not for
    # others, so the map is explicit and this pins the ones that would break.
    assert acp.AGENT_METHODS["auth_login"] == "auth/login"
    assert acp.AGENT_METHODS["session_set_config_option"] == "session/set_config_option"
    assert acp.CLIENT_METHODS["session_request_permission"] == "session/request_permission"


def test_v1_only_methods_are_absent():
    for gone in ("authenticate", "session_load", "session_set_mode"):
        assert gone not in acp.AGENT_METHODS


# ── permission outcome shape ─────────────────────────────────────────────

_PERMISSION_PARAMS = {
    "sessionId": "s1",
    "title": "write file",
    "options": [
        {"optionId": "reject-1", "name": "Reject", "kind": "reject_once"},
        {"optionId": "allow-1", "name": "Allow once", "kind": "allow_once"},
    ],
}


def test_allow_once_selects_a_real_option_id():
    # ACP's outcome is a tagged union carrying an optionId from params.options.
    # An agent receiving an unknown tag MUST NOT treat it as approval, so the
    # wrong shape does not fail loudly -- it silently loses the gate.
    outcome = acp.allow_once(_PERMISSION_PARAMS)
    assert outcome == {"outcome": "selected", "optionId": "allow-1"}


def test_allow_once_cancels_when_no_permitting_option_exists():
    outcome = acp.allow_once({"options": [{"optionId": "r", "kind": "reject_once"}]})
    assert outcome == {"outcome": "cancelled"}


def test_deny_is_the_cancelled_outcome():
    assert acp.deny(_PERMISSION_PARAMS) == {"outcome": "cancelled"}


def test_option_selection_prefers_kind_over_ordering():
    # Nothing in the protocol guarantees option order.
    params = {"options": [
        {"optionId": "always", "kind": "allow_always"},
        {"optionId": "once", "kind": "allow_once"},
    ]}
    assert acp.select_permission_option(params, ("allow_once", "allow_always")) == "once"


# ── framing ──────────────────────────────────────────────────────────────

def test_decode_skips_noise_without_dropping_the_session():
    stream = io.BytesIO(
        b"starting up...\n"
        + acp.encode({"jsonrpc": "2.0", "id": 1, "result": {"ok": True}})
        + b'{"not":"jsonrpc"}\n'
    )
    messages = list(acp.decode_stream(stream))
    assert len(messages) == 1


# ── client contract ──────────────────────────────────────────────────────

def test_a_client_without_a_permission_handler_is_refused():
    with pytest.raises(acp.AcpError) as excinfo:
        acp.AcpClient(["true"], permission_handler=None)
    assert "permission handler" in str(excinfo.value)


def test_cancel_is_a_notification_not_a_request():
    # Sent as a request it blocks forever on a reply the agent never sends, and
    # there is then no way to interrupt a running prompt.
    client = acp.AcpClient(["true"], permission_handler=acp.allow_once)
    with pytest.raises(acp.AcpError) as excinfo:
        client.request("session_cancel", {"sessionId": "s"})
    assert "notification" in str(excinfo.value)


def test_notify_refuses_a_method_that_is_not_a_notification():
    client = acp.AcpClient(["true"], permission_handler=acp.allow_once)
    with pytest.raises(acp.AcpError):
        client.notify("session_prompt", {})


def test_client_rejects_a_method_outside_the_protocol():
    client = acp.AcpClient(["true"], permission_handler=acp.allow_once)
    with pytest.raises(acp.AcpError):
        client.request("session_teleport")


class _FakeProc:
    def __init__(self, script: bytes):
        self.stdin = io.BytesIO()
        self.stdout = io.BytesIO(script)
        self.stderr = io.BytesIO(b"")
        self.killed = False

    def kill(self):
        self.killed = True

    def wait(self, timeout=None):
        return 0


def _client(script: bytes, **kwargs):
    client = acp.AcpClient(["true"], **kwargs)
    client._proc = _FakeProc(script)
    client._next_id = 0
    return client


def test_pump_answers_a_permission_callback_instead_of_deadlocking():
    script = (
        acp.encode({"jsonrpc": "2.0", "id": 99, "method": "session/request_permission",
                    "params": _PERMISSION_PARAMS})
        + acp.encode({"jsonrpc": "2.0", "id": 1, "result": {"stopReason": "end_turn"}})
    )
    client = _client(script, permission_handler=acp.allow_once)
    result = client.request("session_prompt", {"prompt": "hi"})

    assert result == {"stopReason": "end_turn"}
    replies = [json.loads(l) for l in client._proc.stdin.getvalue().splitlines() if l.strip()]
    granted = next(r for r in replies if r.get("id") == 99)
    assert granted["result"]["outcome"] == {"outcome": "selected", "optionId": "allow-1"}


def test_session_updates_reach_the_log_callback():
    seen = []
    script = (
        acp.encode({"jsonrpc": "2.0", "method": "session/update",
                    "params": {"sessionUpdate": "agent_message_chunk"}})
        + acp.encode({"jsonrpc": "2.0", "id": 1, "result": {}})
    )
    _client(script, permission_handler=acp.allow_once, on_update=seen.append).request("session_prompt")
    assert seen and seen[0]["sessionUpdate"] == "agent_message_chunk"


def test_a_falsy_result_is_not_coerced_to_an_empty_object():
    # "answered false" and "answered with an object" are different answers.
    script = acp.encode({"jsonrpc": "2.0", "id": 1, "result": False})
    assert _client(script, permission_handler=acp.allow_once).request("session_list") is False


def test_a_closed_connection_reports_the_peer_stderr():
    client = _client(b"", permission_handler=acp.allow_once)
    client._stderr_bytes = b"auth failed: no API key\n"
    with pytest.raises(acp.AcpError) as excinfo:
        client.request("session_prompt")
    assert "auth failed" in str(excinfo.value)


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
    assert acp_variants <= set(sl.EVENT_TYPES)


# ── stderr must be drained, against a real process ───────────────────────

def test_a_chatty_agent_does_not_deadlock_the_bridge():
    """Undrained stderr fills the pipe buffer and stops the peer writing stdout."""
    noise = "x" * 200  # ~200 KB total, well past a 64 KB pipe buffer
    program = (
        "import sys\n"
        f"for _ in range(1000): sys.stderr.write({noise!r} + chr(10))\n"
        "sys.stderr.flush()\n"
        'sys.stdout.write(\'{"jsonrpc":"2.0","id":1,"result":{"ok":true}}\' + chr(10))\n'
        "sys.stdout.flush()\n"
    )
    client = acp.AcpClient([sys.executable, "-c", program], permission_handler=acp.allow_once)
    client.start()
    try:
        done: list = []
        worker = threading.Thread(target=lambda: done.append(client.request("session_list")))
        worker.start()
        worker.join(timeout=30)
        assert not worker.is_alive(), "bridge deadlocked on an undrained stderr pipe"
        assert done == [{"ok": True}]
    finally:
        client.close()


def test_close_reaps_a_peer_that_outlives_stdin_without_hanging():
    # The earlier version of this test PASSED while waiting out the child's full
    # 60s sleep: _drain_stderr held a read on stderr, so closing that pipe first
    # blocked and wait() was never reached. Timing it is what makes the deadlock
    # visible rather than merely slow.
    client = acp.AcpClient([sys.executable, "-c", "import time; time.sleep(60)"],
                           permission_handler=acp.allow_once)
    client.start()
    proc = client._proc
    started = time.monotonic()
    client.close()
    elapsed = time.monotonic() - started
    assert proc.poll() is not None, "child was not reaped"
    assert elapsed < 20, f"close() blocked for {elapsed:.1f}s on a live peer"


# ── server contract ──────────────────────────────────────────────────────

def test_server_refuses_a_method_outside_the_protocol():
    out = io.BytesIO()
    acp.AcpAgentServer(lambda m, p: {}, stdin=io.BytesIO(
        acp.encode({"jsonrpc": "2.0", "id": 5, "method": "session/teleport"})
    ), stdout=out).serve_forever()
    assert json.loads(out.getvalue())["error"]["code"] == -32601


def test_server_dispatches_a_notification_so_stop_actually_stops():
    # session/cancel is a notification. Dropping notifications means a client
    # pressing stop has no effect and Legion keeps burning a metered run.
    seen = []
    out = io.BytesIO()
    acp.AcpAgentServer(lambda m, p: seen.append((m, p)), stdin=io.BytesIO(
        acp.encode({"jsonrpc": "2.0", "method": "session/cancel", "params": {"sessionId": "s"}})
    ), stdout=out).serve_forever()
    # The client's cancel, distinguishable from the synthetic one the server
    # raises at EOF so a handler can unwind work whose requester has left.
    assert ("session_cancel", {"sessionId": "s"}) in seen
    assert out.getvalue() == b"", "a notification must not be answered"


def test_server_ignores_a_response_arriving_on_stdin():
    out = io.BytesIO()
    acp.AcpAgentServer(lambda m, p: {}, stdin=io.BytesIO(
        acp.encode({"jsonrpc": "2.0", "id": 7, "result": {"whatever": True}})
    ), stdout=out).serve_forever()
    assert out.getvalue() == b"", "a response is not an unsupported method"


def test_server_reports_a_handler_fault_without_killing_the_session():
    def boom(method, params):
        raise RuntimeError("handler exploded")

    out = io.BytesIO()
    stdin = io.BytesIO(
        acp.encode({"jsonrpc": "2.0", "id": 1, "method": "session/new"})
        + acp.encode({"jsonrpc": "2.0", "id": 2, "method": "session/list"})
    )
    acp.AcpAgentServer(boom, stdin=stdin, stdout=out).serve_forever()
    replies = [json.loads(l) for l in out.getvalue().splitlines()]
    assert len(replies) == 2
    assert all(r["error"]["code"] == -32603 for r in replies)


# ── registry ─────────────────────────────────────────────────────────────

def test_acp_capability_is_declared_and_currently_unexercised():
    """A tripwire, not a speed bump: enabling an executor edits the allowlist."""
    import importlib.util as _u
    spec = _u.spec_from_file_location(
        "lroute", os.path.join(HERE, "..", "..", "legion-router", "scripts", "legion-route.py")
    )
    route = _u.module_from_spec(spec)
    spec.loader.exec_module(route)

    execs = route.load_executors(
        os.path.join(HERE, "..", "..", "legion-router", "config", "executors.toml")
    )
    enabled_for_acp: set[str] = set()   # add an executor here once it is exercised

    assert execs
    for name, entry in execs.items():
        assert "acp" in entry, f"{name} must declare whether it can be driven over ACP"
        assert isinstance(entry["acp"], bool), f"{name}.acp must be a boolean"
        if name not in enabled_for_acp:
            assert entry["acp"] is False, (
                f"{name} claims ACP without being in the exercised allowlist; add it "
                f"to enabled_for_acp once a real session has run over the bridge"
            )


def test_server_ignores_a_request_only_method_sent_without_an_id():
    # session/delete arriving as a notification is malformed. Running it would
    # perform its side effects while answering nobody.
    seen = []
    out = io.BytesIO()
    acp.AcpAgentServer(lambda m, p: seen.append((m, p)), stdin=io.BytesIO(
        acp.encode({"jsonrpc": "2.0", "method": "session/delete", "params": {}})
    ), stdout=out).serve_forever()
    dispatched = [m for m, p in seen if p.get("reason") != "client_disconnected"]
    assert dispatched == [], "a request-only method must not be dispatched without an id"
    assert out.getvalue() == b""


def test_server_reads_cancel_while_a_prompt_handler_is_still_running():
    """An editor's Stop must land during the prompt, not after it."""
    prompt_running = threading.Event()
    release = threading.Event()
    seen = []

    def handler(method, params):
        seen.append(method)
        if method == "session_prompt":
            prompt_running.set()
            release.wait(timeout=10)   # stands in for delegated work
            return {"stopReason": "cancelled"}
        return {}

    out = io.BytesIO()
    stdin = io.BytesIO(
        acp.encode({"jsonrpc": "2.0", "id": 1, "method": "session/prompt", "params": {}})
        + acp.encode({"jsonrpc": "2.0", "method": "session/cancel", "params": {"sessionId": "s"}})
    )
    server = acp.AcpAgentServer(handler, stdin=stdin, stdout=out)
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()

    assert prompt_running.wait(timeout=10), "prompt handler never started"
    deadline = time.monotonic() + 10
    while "session_cancel" not in seen and time.monotonic() < deadline:
        time.sleep(0.05)
    release.set()
    thread.join(timeout=15)

    assert "session_cancel" in seen, (
        "cancel was not read until the prompt finished; Stop would do nothing"
    )


def test_server_signals_disconnect_so_orphaned_work_can_unwind():
    # A client vanishing mid-prompt used to leave a daemon worker to be killed
    # at process exit, abandoning a delegated run, its subprocesses and its
    # worktree. The handler is told, and owned workers are waited for.
    seen = []
    acp.AcpAgentServer(lambda m, p: seen.append((m, p)),
                       stdin=io.BytesIO(b""), stdout=io.BytesIO()).serve_forever()
    assert ("session_cancel", {"reason": "client_disconnected"}) in seen


def test_cancel_cannot_overtake_the_prompt_it_means_to_stop():
    # worker.start() only SCHEDULES. The reader could dispatch the cancel before
    # the prompt handler registered its run, so Stop found nothing to stop and
    # the prompt ran on regardless.
    order = []
    release = threading.Event()

    def handler(method, params):
        order.append(method)
        if method == "session_prompt":
            release.wait(timeout=10)
        return {}

    stdin = io.BytesIO(
        acp.encode({"jsonrpc": "2.0", "id": 1, "method": "session/prompt", "params": {"sessionId": "s"}})
        + acp.encode({"jsonrpc": "2.0", "method": "session/cancel", "params": {"sessionId": "s"}})
    )
    server = acp.AcpAgentServer(handler, stdin=stdin, stdout=io.BytesIO())
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()

    deadline = time.monotonic() + 10
    while "session_cancel" not in order and time.monotonic() < deadline:
        time.sleep(0.02)
    release.set()
    thread.join(timeout=15)

    assert order[0] == "session_prompt", (
        f"cancel overtook the prompt it was meant to stop: {order}"
    )


def test_cancellation_is_sticky_for_a_late_registering_handler():
    # Ordering alone is not enough when a handler registers its work several
    # hops in; recording the cancel means the answer survives the race.
    server = acp.AcpAgentServer(lambda m, p: {}, stdin=io.BytesIO(b""), stdout=io.BytesIO())
    assert server.is_cancelled("s") is False
    server.begin_prompt("s")          # a prompt is now running
    server._dispatch_notification("session_cancel", {"sessionId": "s"})
    assert server.is_cancelled("s") is True


def test_close_kills_a_descendant_left_behind_by_an_exited_leader():
    # start_new_session detaches the group. A leader that exits cleanly skipped
    # every signalling branch, so its descendants survived close() outright.
    marker = os.path.join(os.environ.get("TMPDIR", "/tmp"), f"acp-orphan-{os.getpid()}")
    program = (
        "import os, subprocess, sys, time\n"
        f"subprocess.Popen([sys.executable,'-c','import time,os\\nopen({marker!r},\\'w\\').close()\\ntime.sleep(120)'])\n"
        "sys.stdout.flush()\n"          # leader exits immediately, child lives on
    )
    client = acp.AcpClient([sys.executable, "-c", program], permission_handler=acp.allow_once)
    client.start()
    pgid = client._pgid
    for _ in range(100):                # wait for the grandchild to exist
        if os.path.exists(marker):
            break
        time.sleep(0.05)
    started = time.monotonic()
    client.close()
    elapsed = time.monotonic() - started

    assert elapsed < 20, f"close() blocked for {elapsed:.1f}s on a surviving descendant"
    if pgid is not None:
        try:
            os.killpg(pgid, 0)
            raise AssertionError("the detached group outlived close()")
        except (ProcessLookupError, PermissionError, OSError):
            pass  # group is gone, which is the point
    try:
        os.unlink(marker)
    except OSError:
        pass


def test_cancellation_is_readable_whenever_the_handler_gets_there():
    # The point of a token: a handler that registers work long after the cancel
    # arrived still reads it. A replay could never cover a run slower than its
    # own delay.
    server = acp.AcpAgentServer(lambda m, p: {}, stdin=io.BytesIO(b""), stdout=io.BytesIO())
    server.begin_prompt("s")
    server._dispatch_notification("session_cancel", {"sessionId": "s"})
    time.sleep(0.6)                      # far longer than the old 250ms replay
    assert server.is_cancelled("s") is True

def test_stderr_tail_is_bounded_by_bytes_not_lines():
    # One unterminated line buffers entirely before a line cap can apply, so a
    # malformed peer could exhaust memory despite the cap looking present.
    program = (
        "import sys\n"
        "sys.stderr.write('x' * 5_000_000)\n"   # a single 5 MB line, no newline
        "sys.stderr.flush()\n"
        'sys.stdout.write(\'{"jsonrpc":"2.0","id":1,"result":{}}\' + chr(10))\n'
        "sys.stdout.flush()\n"
    )
    client = acp.AcpClient([sys.executable, "-c", program], permission_handler=acp.allow_once)
    client.start()
    try:
        client.request("session_list")
        deadline = time.monotonic() + 10
        while client._proc.poll() is None and time.monotonic() < deadline:
            time.sleep(0.05)
        time.sleep(0.5)
        assert len(client._stderr_bytes) <= acp.AcpClient.STDERR_TAIL_BYTES, (
            f"stderr tail grew to {len(client._stderr_bytes)} bytes"
        )
    finally:
        client.close()


def test_pgid_is_the_child_pid_and_survives_a_fast_leader():
    # getpgid races a launcher that exits immediately; start_new_session
    # guarantees pgid == pid, so it is taken directly and cannot be lost.
    client = acp.AcpClient([sys.executable, "-c", "pass"], permission_handler=acp.allow_once)
    client.start()
    assert client._pgid == client._proc.pid
    client.close()


def test_cancellation_does_not_leak_into_a_later_prompt():
    # A cancel targets the prompt that was running. Left set, every later prompt
    # in that session would start already cancelled.
    server = acp.AcpAgentServer(lambda m, p: {}, stdin=io.BytesIO(b""), stdout=io.BytesIO())
    server.begin_prompt("s")
    server._dispatch_notification("session_cancel", {"sessionId": "s"})
    assert server.is_cancelled("s") is True
    server.end_prompt("s")
    assert server.is_cancelled("s") is False, "cancellation leaked past its turn"
    server.begin_prompt("s")          # the next prompt
    assert server.is_cancelled("s") is False, "a new prompt started already cancelled"


def test_a_new_prompt_starts_uncancelled():
    # Replaced the old replay-timing test: there is no replay any more. A token
    # consumed at registration cannot be aimed at the wrong turn, because it is
    # read when the handler is ready rather than delivered on a timer.
    server = acp.AcpAgentServer(lambda m, p: {}, stdin=io.BytesIO(b""), stdout=io.BytesIO())
    server.begin_prompt("s")
    server._dispatch_notification("session_cancel", {"sessionId": "s"})
    assert server.is_cancelled("s") is True
    server.end_prompt("s")
    server.begin_prompt("s")
    assert server.is_cancelled("s") is False, "a new prompt inherited a stale cancel"

def test_stderr_tail_is_readable_before_the_drainer_sees_eof():
    client = acp.AcpClient(["true"], permission_handler=acp.allow_once)
    client._stderr_bytes = b"partial diagnostics\nsecond line\n"
    assert client.stderr_tail == ["partial diagnostics", "second line"]


def test_a_cancel_with_no_running_prompt_marks_nothing():
    # Reading the turn counter after _end_turn advanced it used to mark the NEXT
    # prompt cancelled before it had even started.
    server = acp.AcpAgentServer(lambda m, p: {}, stdin=io.BytesIO(b""), stdout=io.BytesIO())
    server._dispatch_notification("session_cancel", {"sessionId": "s"})
    server.begin_prompt("s")
    assert server.is_cancelled("s") is False, "a stray cancel poisoned the next prompt"


def test_permission_is_refused_when_cancel_lands_while_the_handler_decides():
    # The real race: the handler is still deciding when Stop arrives. Checking
    # cancellation before calling it and sending afterwards leaves a window in
    # which a tool is authorised after the user cancelled.
    script = (
        acp.encode({"jsonrpc": "2.0", "id": 99, "method": "session/request_permission",
                    "params": dict(_PERMISSION_PARAMS, sessionId="s")})
        + acp.encode({"jsonrpc": "2.0", "id": 1, "result": {}})
    )
    holder = {}

    def slow_handler(params):
        # Stop is pressed mid-decision, exactly as a user would.
        holder["client"].cancel_local("s")
        return acp.allow_once(params)

    client = _client(script, permission_handler=slow_handler)
    holder["client"] = client
    client.request("session_prompt", {"sessionId": "s"})

    replies = [json.loads(l) for l in client._proc.stdin.getvalue().splitlines() if l.strip()]
    granted = next(r for r in replies if r.get("id") == 99)
    assert granted["result"]["outcome"] == {"outcome": "cancelled"}, (
        "a tool was authorised after Stop landed mid-decision"
    )

def test_permission_is_granted_normally_when_not_cancelled():
    script = (
        acp.encode({"jsonrpc": "2.0", "id": 99, "method": "session/request_permission",
                    "params": dict(_PERMISSION_PARAMS, sessionId="s")})
        + acp.encode({"jsonrpc": "2.0", "id": 1, "result": {}})
    )
    client = _client(script, permission_handler=acp.allow_once)
    client.request("session_prompt", {"sessionId": "s"})
    replies = [json.loads(l) for l in client._proc.stdin.getvalue().splitlines() if l.strip()]
    granted = next(r for r in replies if r.get("id") == 99)
    assert granted["result"]["outcome"]["outcome"] == "selected"


def test_short_stderr_is_readable_before_the_peer_exits():
    # read(8192) waits for a full buffer or EOF, so a short diagnostic stayed
    # invisible exactly when _pump needed it to explain the failure.
    program = (
        "import sys, time\n"
        "sys.stderr.write('boom: short diagnostic\\n'); sys.stderr.flush()\n"
        "time.sleep(5)\n"
    )
    client = acp.AcpClient([sys.executable, "-c", program], permission_handler=acp.allow_once)
    client.start()
    try:
        deadline = time.monotonic() + 5
        while not client.stderr_tail and time.monotonic() < deadline:
            time.sleep(0.05)
        assert any("boom" in line for line in client.stderr_tail), (
            "short stderr was not readable until EOF"
        )
    finally:
        client.close()
