"""Agent Client Protocol bridge: Legion as an ACP client, and as an ACP agent.

Legion maintains a bespoke Bash adapter per executor. Every executor it drives
already speaks ACP -- Claude Code, Codex, Cursor, opencode, Pi and Hermes are all
in the ACP registry -- so one client speaks to all of them, and to the agents
Legion has never integrated, through the same wire.

The other direction matters as much. Speaking ACP as an *agent* puts Legion
inside Zed, JetBrains, Neovim and VS Code without per-editor work, as a governed
router rather than another agent.

Targets ACP **v2**. The wire names are taken from the published schema rather
than derived from Python identifiers: v1 and v2 disagree (v1 has `authenticate`,
`session/load`, `session/set_mode`; v2 has `auth/login` and no load or set_mode),
and a bridge that guesses its own method names is a bridge that fails against a
real peer for reasons nobody can see.

Stdlib only; JSON-RPC 2.0 over newline-delimited JSON on stdio.
"""

from __future__ import annotations

import json
import subprocess
import threading
from typing import Any, Callable, Iterator

PROTOCOL_VERSION = 2

# Identifier -> wire method, verbatim from schema/v2/meta.json. Explicit because
# deriving "session_set_config_option" -> "session/set_config_option" happens to
# work while "auth_login" -> "auth/login" only works by luck of one underscore.
AGENT_METHODS: dict[str, str] = {
    "initialize": "initialize",
    "auth_login": "auth/login",
    "auth_logout": "auth/logout",
    "session_new": "session/new",
    "session_set_config_option": "session/set_config_option",
    "session_prompt": "session/prompt",
    "session_cancel": "session/cancel",
    "session_list": "session/list",
    "session_delete": "session/delete",
    "session_resume": "session/resume",
    "session_close": "session/close",
}

CLIENT_METHODS: dict[str, str] = {
    "session_request_permission": "session/request_permission",
    "session_update": "session/update",
    "elicitation_create": "elicitation/create",
    "elicitation_complete": "elicitation/complete",
}

# session/cancel is a NOTIFICATION: the agent sends no response. Dispatching it
# as a request blocks forever waiting for a reply that will never come, which
# also means there is no way to interrupt a running prompt -- a hard requirement
# for a metered router.
AGENT_NOTIFICATIONS = frozenset({"session_cancel"})

_WIRE_TO_CLIENT = {wire: name for name, wire in CLIENT_METHODS.items()}


class AcpError(RuntimeError):
    """The peer violated the protocol, or refused."""


class _Missing:
    """Sentinel: distinguishes "no result field" from a falsy result."""


def encode(message: dict[str, Any]) -> bytes:
    return (json.dumps(message, separators=(",", ":")) + "\n").encode("utf-8")


def decode_stream(stream: Any) -> Iterator[dict[str, Any]]:
    """Yield JSON-RPC messages, skipping lines that are not messages.

    A banner on stdout must not kill the session. Note the cost of this
    tolerance: a truncated or oversized line is indistinguishable from noise and
    surfaces later as "closed the connection", so callers should not read a
    missing response as proof the peer said nothing.
    """
    for raw in stream:
        line = raw.decode("utf-8", "replace").strip() if isinstance(raw, bytes) else raw.strip()
        if not line:
            continue
        try:
            message = json.loads(line)
        except ValueError:
            continue
        if isinstance(message, dict) and message.get("jsonrpc") == "2.0":
            yield message


def select_permission_option(params: dict[str, Any], kinds: tuple[str, ...]) -> str | None:
    """Pick an option id from a permission request, by preferred kind.

    ACP presents options rather than a boolean, and the reply must echo one of
    their ids. Choosing by `kind` keeps a policy readable ("allow once") instead
    of depending on option ordering, which no part of the protocol guarantees.
    """
    options = params.get("options")
    if not isinstance(options, list):
        return None
    for wanted in kinds:
        for option in options:
            if isinstance(option, dict) and option.get("kind") == wanted:
                option_id = option.get("optionId")
                if isinstance(option_id, str) and option_id:
                    return option_id
    return None


def allow_once(params: dict[str, Any]) -> dict[str, Any]:
    """A conservative default policy: the narrowest approval on offer.

    Returns the ACP outcome object, not a bare string -- the response is a tagged
    union of {"outcome":"selected","optionId":…} and {"outcome":"cancelled"}, and
    an agent that receives an unknown tag MUST NOT treat it as approval. Emitting
    the wrong shape therefore does not fail loudly, it silently loses the gate.
    """
    option_id = select_permission_option(params, ("allow_once", "allow_always"))
    if option_id is None:
        return {"outcome": "cancelled"}
    return {"outcome": "selected", "optionId": option_id}


def deny(_params: dict[str, Any]) -> dict[str, Any]:
    return {"outcome": "cancelled"}


class AcpClient:
    """Drive any ACP agent as a Legion executor.

    The permission handler is required rather than defaulted: an ACP client that
    silently approves everything is a worse position than the Bash adapters this
    replaces, because the protocol offered the gate and it was declined.
    """

    def __init__(self, argv: list[str], *,
                 permission_handler: Callable[[dict[str, Any]], dict[str, Any]],
                 on_update: Callable[[dict[str, Any]], None] | None = None,
                 cwd: str | None = None) -> None:
        if not callable(permission_handler):
            raise AcpError(
                "an ACP client must supply a permission handler; session/request_permission "
                "is a client method and declining to implement it means approving everything"
            )
        self.argv = argv
        self.permission_handler = permission_handler
        self.on_update = on_update
        self.cwd = cwd
        self._next_id = 0
        self._proc: subprocess.Popen[bytes] | None = None
        self._id_lock = threading.Lock()
        self._send_lock = threading.Lock()
        self._stderr_thread: threading.Thread | None = None
        self.stderr_tail: list[str] = []

    def _request_id(self) -> int:
        with self._id_lock:
            self._next_id += 1
            return self._next_id

    def start(self) -> None:
        self._proc = subprocess.Popen(
            self.argv, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
            stderr=subprocess.PIPE, cwd=self.cwd,
        )
        # stderr MUST be drained. A chatty agent fills the OS pipe buffer (~64 KB),
        # blocks in write(2), stops producing stdout, and the reader below waits
        # forever for a response the peer can no longer send. Keeping a bounded
        # tail also means a failure has an explanation attached.
        self._stderr_thread = threading.Thread(target=self._drain_stderr, daemon=True)
        self._stderr_thread.start()

    def _drain_stderr(self) -> None:
        proc = self._proc
        if proc is None or proc.stderr is None:
            return
        for line in proc.stderr:
            text = line.decode("utf-8", "replace").rstrip()
            self.stderr_tail.append(text)
            if len(self.stderr_tail) > 200:
                del self.stderr_tail[0]

    def _send(self, message: dict[str, Any]) -> None:
        if self._proc is None or self._proc.stdin is None:
            raise AcpError("ACP client is not started")
        with self._send_lock:
            self._proc.stdin.write(encode(message))
            self._proc.stdin.flush()

    def notify(self, method: str, params: dict[str, Any] | None = None) -> None:
        """Send a notification. No id, no response, no waiting."""
        if method not in AGENT_NOTIFICATIONS:
            raise AcpError(f"{method!r} is not an ACP notification; use request()")
        self._send({"jsonrpc": "2.0", "method": AGENT_METHODS[method], "params": params or {}})

    def cancel(self, session_id: str) -> None:
        """Interrupt a running prompt. Safe to call from another thread."""
        self.notify("session_cancel", {"sessionId": session_id})

    def request(self, method: str, params: dict[str, Any] | None = None) -> Any:
        if method in AGENT_NOTIFICATIONS:
            raise AcpError(f"{method!r} is a notification; use notify() or cancel()")
        if method not in AGENT_METHODS:
            raise AcpError(f"{method!r} is not an ACP agent method")
        request_id = self._request_id()
        self._send({"jsonrpc": "2.0", "id": request_id,
                    "method": AGENT_METHODS[method], "params": params or {}})
        return self._pump(until_id=request_id)

    def _pump(self, *, until_id: int) -> Any:
        """Read until our response arrives, servicing the agent's calls meanwhile.

        An ACP agent calls BACK during a prompt -- for permission, for
        elicitation. Waiting only for the response would deadlock the moment the
        agent asks a question, so the reader answers those inline.

        Single-reader by design: this owns the stdout iterator, so cancellation
        goes out as a notification from another thread rather than a second pump
        competing for the same messages.
        """
        if self._proc is None or self._proc.stdout is None:
            raise AcpError("ACP client is not started")
        for message in decode_stream(self._proc.stdout):
            if message.get("id") == until_id and ("result" in message or "error" in message):
                if "error" in message:
                    raise AcpError(f"agent returned an error: {message['error']}")
                # A result of null/false/0/"" is a real answer, not an absent one.
                result = message.get("result", _Missing)
                return {} if result is _Missing else result
            wire = str(message.get("method") or "")
            name = _WIRE_TO_CLIENT.get(wire)
            if name == "session_update":
                if self.on_update:
                    self.on_update(message.get("params") or {})
                continue
            if name == "session_request_permission":
                outcome = self.permission_handler(message.get("params") or {})
                self._send({"jsonrpc": "2.0", "id": message.get("id"),
                            "result": {"outcome": outcome}})
                continue
            if name in ("elicitation_create", "elicitation_complete"):
                # Legion runs unattended. Declining is the honest answer; making
                # one up would put invented content into the agent's context.
                self._send({"jsonrpc": "2.0", "id": message.get("id"),
                            "result": {"action": "decline"}})
                continue
        tail = "; ".join(self.stderr_tail[-3:])
        raise AcpError(
            "agent closed the connection before answering"
            + (f" (stderr: {tail})" if tail else "")
        )

    def close(self) -> None:
        """Shut the peer down without leaking a zombie or its pipes."""
        proc = self._proc
        if proc is None:
            return
        for pipe in (proc.stdin, proc.stdout, proc.stderr):
            if pipe is None:
                continue
            try:
                pipe.close()
            except OSError:
                pass  # already closed, or the peer went away first
        try:
            proc.wait(timeout=10)
        except subprocess.TimeoutExpired:
            proc.kill()
            proc.wait()  # reap it; kill() alone leaves a zombie until we exit
        self._proc = None


class AcpAgentServer:
    """Serve Legion to any ACP client (Zed, JetBrains, Neovim, VS Code).

    Legion appears as one agent whose work is routed, isolated in a worktree and
    metered -- the governance an editor cannot provide for itself.
    """

    def __init__(self, handler: Callable[[str, dict[str, Any]], Any],
                 *, stdin: Any = None, stdout: Any = None) -> None:
        self.handler = handler
        if stdin is None or stdout is None:
            import sys
            stdin = stdin if stdin is not None else sys.stdin.buffer
            stdout = stdout if stdout is not None else sys.stdout.buffer
        self.stdin = stdin
        self.stdout = stdout

    def _write(self, message: dict[str, Any]) -> None:
        self.stdout.write(encode(message))
        self.stdout.flush()

    def serve_forever(self) -> None:
        for message in decode_stream(self.stdin):
            request_id = message.get("id")
            wire = str(message.get("method") or "")

            if not wire:
                continue  # a response to something we sent; nothing to dispatch

            name = next((k for k, v in AGENT_METHODS.items() if v == wire), None)

            if request_id is None:
                # A notification still needs dispatching. session/cancel arrives
                # this way, so dropping notifications means a client pressing
                # stop has no effect and Legion keeps burning a metered run.
                if name is not None:
                    try:
                        self.handler(name, message.get("params") or {})
                    except Exception:  # noqa: BLE001 - a notification has nobody to tell
                        pass
                continue

            if name is None:
                self._write({"jsonrpc": "2.0", "id": request_id,
                             "error": {"code": -32601, "message": f"unsupported method: {wire}"}})
                continue
            try:
                result = self.handler(name, message.get("params") or {})
            except Exception as exc:  # noqa: BLE001 - a handler fault must not kill the session
                self._write({"jsonrpc": "2.0", "id": request_id,
                             "error": {"code": -32603, "message": str(exc)}})
                continue
            self._write({"jsonrpc": "2.0", "id": request_id,
                         "result": {} if result is None else result})
