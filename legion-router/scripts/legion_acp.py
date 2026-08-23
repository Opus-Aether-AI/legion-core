"""Agent Client Protocol bridge: Legion as an ACP client, and as an ACP agent.

Legion maintains a bespoke Bash adapter per executor. Every executor it drives
already speaks ACP -- Claude Code, Codex, Cursor, opencode, Pi and Hermes are all
in the ACP registry -- so one client speaks to all of them, and to the thirty-odd
agents Legion has never integrated, through the same wire.

The other direction matters as much. Speaking ACP as an *agent* puts Legion
inside Zed, JetBrains, Neovim and VS Code without per-editor work, as a governed
router rather than another agent.

Two protocol facts shaped this file:

- ``session/request_permission`` is a CLIENT method. The thing driving the agent
  decides what it may do, which is exactly Legion's governance role -- so the
  permission gate is not something bolted on here, it is where the protocol
  already puts it.
- ``session/update`` carries the SessionUpdate variants that legion.session-event.v2
  already adopted, so an ACP stream lands in Legion's own log with no
  translation layer to drift.

Stdlib only; JSON-RPC 2.0 over newline-delimited JSON on stdio.
"""

from __future__ import annotations

import json
import subprocess
import sys
import threading
from typing import Any, Callable, Iterator

PROTOCOL_VERSION = 2

AGENT_METHODS = (
    "initialize", "auth_login", "session_new", "session_set_config_option",
    "session_prompt", "session_cancel", "session_list", "session_delete",
    "session_resume", "session_close", "auth_logout",
)
CLIENT_METHODS = (
    "session_request_permission", "session_update",
    "elicitation_create", "elicitation_complete",
)


class AcpError(RuntimeError):
    """The peer violated the protocol, or refused."""


def _wire(method: str) -> str:
    """meta.json names methods with underscores; the wire uses slashes."""
    head, _, tail = method.partition("_")
    return f"{head}/{tail}" if tail else head


def encode(message: dict[str, Any]) -> bytes:
    return (json.dumps(message, separators=(",", ":")) + "\n").encode("utf-8")


def decode_stream(stream: Any) -> Iterator[dict[str, Any]]:
    """Yield JSON-RPC messages, skipping lines that are not messages.

    A peer's stderr or a stray banner on stdout must not kill the session: an
    unparseable line is noise, and treating noise as a protocol violation would
    make the bridge fail on cosmetics.
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


class AcpClient:
    """Drive any ACP agent as a Legion executor.

    Replaces a bespoke adapter per vendor. The permission handler is required
    rather than defaulted: an ACP client that silently approves everything is a
    worse position than the Bash adapters this replaces, because the protocol
    offered the gate and it was declined.
    """

    def __init__(self, argv: list[str], *, permission_handler: Callable[[dict[str, Any]], str],
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
        self._lock = threading.Lock()

    def _request_id(self) -> int:
        with self._lock:
            self._next_id += 1
            return self._next_id

    def start(self) -> None:
        self._proc = subprocess.Popen(
            self.argv, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
            stderr=subprocess.PIPE, cwd=self.cwd,
        )

    def _send(self, message: dict[str, Any]) -> None:
        if self._proc is None or self._proc.stdin is None:
            raise AcpError("ACP client is not started")
        self._proc.stdin.write(encode(message))
        self._proc.stdin.flush()

    def request(self, method: str, params: dict[str, Any] | None = None) -> dict[str, Any]:
        if method not in AGENT_METHODS:
            raise AcpError(f"{method!r} is not an ACP agent method")
        request_id = self._request_id()
        self._send({"jsonrpc": "2.0", "id": request_id, "method": _wire(method),
                    "params": params or {}})
        return self._pump(until_id=request_id)

    def _pump(self, *, until_id: int) -> dict[str, Any]:
        """Read until our response arrives, servicing the agent's calls meanwhile.

        An ACP agent calls BACK during a prompt -- for permission, for
        elicitation. Waiting only for the response would deadlock the moment the
        agent asks a question, so the reader answers those inline.
        """
        if self._proc is None or self._proc.stdout is None:
            raise AcpError("ACP client is not started")
        for message in decode_stream(self._proc.stdout):
            if message.get("id") == until_id and ("result" in message or "error" in message):
                if "error" in message:
                    raise AcpError(f"agent returned an error: {message['error']}")
                return message.get("result") or {}
            method = str(message.get("method") or "").replace("/", "_")
            if method == "session_update":
                if self.on_update:
                    self.on_update(message.get("params") or {})
                continue
            if method == "session_request_permission":
                outcome = self.permission_handler(message.get("params") or {})
                self._send({"jsonrpc": "2.0", "id": message.get("id"),
                            "result": {"outcome": {"outcome": outcome}}})
                continue
            if method == "elicitation_create":
                # Legion runs unattended. Declining is the honest answer; making
                # one up would put invented content into the agent's context.
                self._send({"jsonrpc": "2.0", "id": message.get("id"),
                            "result": {"action": "decline"}})
                continue
        raise AcpError("agent closed the connection before answering")

    def close(self) -> None:
        if self._proc is None:
            return
        try:
            if self._proc.stdin:
                self._proc.stdin.close()
            self._proc.wait(timeout=10)
        except Exception:
            self._proc.kill()


class AcpAgentServer:
    """Serve Legion to any ACP client (Zed, JetBrains, Neovim, VS Code).

    Legion appears as one agent whose work is routed, isolated in a worktree and
    metered -- the governance an editor cannot provide for itself.
    """

    def __init__(self, handler: Callable[[str, dict[str, Any]], dict[str, Any]],
                 *, stdin: Any = None, stdout: Any = None) -> None:
        self.handler = handler
        self.stdin = stdin if stdin is not None else sys.stdin.buffer
        self.stdout = stdout if stdout is not None else sys.stdout.buffer

    def _write(self, message: dict[str, Any]) -> None:
        self.stdout.write(encode(message))
        self.stdout.flush()

    def serve_forever(self) -> None:
        for message in decode_stream(self.stdin):
            request_id = message.get("id")
            method = str(message.get("method") or "").replace("/", "_")
            if request_id is None:
                continue  # a notification; nothing to answer
            if method not in AGENT_METHODS:
                self._write({"jsonrpc": "2.0", "id": request_id,
                             "error": {"code": -32601, "message": f"unsupported method: {method}"}})
                continue
            try:
                result = self.handler(method, message.get("params") or {})
            except Exception as exc:  # noqa: BLE001 - a handler fault must not kill the session
                self._write({"jsonrpc": "2.0", "id": request_id,
                             "error": {"code": -32603, "message": str(exc)}})
                continue
            self._write({"jsonrpc": "2.0", "id": request_id, "result": result})
