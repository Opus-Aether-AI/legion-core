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
import os
import signal
import subprocess
import time
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

    STDERR_TAIL_BYTES = 64 * 1024

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
        self._pgid: int | None = None
        self._stderr_bytes = b""
        self._cancelled_lock = threading.Lock()
        self._pending_permissions: dict[Any, Any] = {}
        self._permission_workers: list[threading.Thread] = []
        self._cancelled_sessions: set[str] = set()

    def _request_id(self) -> int:
        with self._id_lock:
            self._next_id += 1
            return self._next_id

    def start(self) -> None:
        # Own the whole process GROUP. An agent that spawns a child which
        # inherits stderr keeps that pipe open after the agent itself exits, and
        # closing it below would then block on the drainer's reader lock until
        # the descendant happens to finish.
        self._proc = subprocess.Popen(
            self.argv, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
            stderr=subprocess.PIPE, cwd=self.cwd, start_new_session=True,
        )
        # start_new_session guarantees the new process group id IS the child's
        # pid, so take it directly. Querying getpgid races a fast launcher that
        # exits before the call -- and losing the id means losing the only handle
        # on any descendant still running in that detached group.
        self._pgid = self._proc.pid
        # stderr MUST be drained. A chatty agent fills the OS pipe buffer (~64 KB),
        # blocks in write(2), stops producing stdout, and the reader below waits
        # forever for a response the peer can no longer send. Keeping a bounded
        # tail also means a failure has an explanation attached.
        self._stderr_thread = threading.Thread(target=self._drain_stderr, daemon=True)
        self._stderr_thread.start()

    def _drain_stderr(self) -> None:
        """Drain in fixed-size chunks, keeping a byte-bounded tail.

        Iterating by line buffers a whole line before any cap can apply, so one
        very large or unterminated line from a malformed peer exhausts memory --
        the cap has to be on bytes read, not lines kept.
        """
        proc = self._proc
        if proc is None or proc.stderr is None:
            return
        buffer = b""
        while True:
            # read1(), not read(): read() waits for a full buffer or EOF, so a
            # peer that writes a short diagnostic and then leaves stderr open in
            # a descendant would have it sitting unread precisely when _pump
            # needs it to explain the failure.
            chunk = proc.stderr.read1(8192) if hasattr(proc.stderr, "read1") else proc.stderr.read(1)
            if not chunk:
                break
            buffer = (buffer + chunk)[-self.STDERR_TAIL_BYTES:]
            self._stderr_bytes = buffer

    @property
    def stderr_tail(self) -> list[str]:
        """The peer's recent stderr, readable BEFORE the drainer sees EOF.

        Publishing only at EOF meant a stdout that closed first -- exactly the
        descendant-holds-stderr case -- raised its error with the diagnostics
        already sitting in the buffer omitted.
        """
        return [
            line for line in self._stderr_bytes.decode("utf-8", "replace").splitlines()
            if line.strip()
        ]

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
        """Interrupt a running prompt. Safe to call from another thread.

        Marker and notification go out under ONE lock, in the order the peer
        sees them. Setting the marker and then sending unlocked left a window in
        which a prompt starting concurrently cleared the marker between the two:
        the cancel then arrived on the wire AFTER the new prompt -- stopping the
        wrong turn at the peer -- while locally nothing was cancelled at all, so
        a permission for the turn being stopped was still approved.
        """
        with self._cancelled_lock:
            self._cancelled_sessions.add(session_id)
            self.notify("session_cancel", {"sessionId": session_id})
        # A gate still waiting on a blocking handler must be released now, not
        # whenever that handler happens to return.
        self._cancel_pending_permissions(session_id)

    def cancel_local(self, session_id: str) -> None:
        """Record a cancellation without sending the notification.

        Used when the peer has already been told, or cannot be: the record is
        what stops a permission being granted, so it must not depend on the
        wire.
        """
        with self._cancelled_lock:
            self._cancelled_sessions.add(session_id)

    def resume(self, session_id: str) -> None:
        """Clear a cancellation so a later prompt in the session is not blocked.

        Without this the marker outlives its turn and every subsequent
        permission request in the session is forced to `cancelled`.
        """
        with self._cancelled_lock:
            self._cancelled_sessions.discard(session_id)

    def is_cancelled(self, session_id: str) -> bool:
        with self._cancelled_lock:
            return session_id in self._cancelled_sessions

    def _begin_permission(self, request_id: Any, params: dict[str, Any]) -> None:
        """Register a permission request and decide it off the read loop."""
        session_id = params.get("sessionId")
        with self._cancelled_lock:
            self._pending_permissions[request_id] = session_id
        # Already cancelled? Answer now; never call the handler at all.
        if self._answer_permission(request_id, None):
            return

        def decide() -> None:
            try:
                outcome = self.permission_handler(params)
            except Exception:  # noqa: BLE001 - a gate that faults must not grant
                outcome = {"outcome": "cancelled"}
            self._answer_permission(request_id, outcome)

        worker = threading.Thread(target=decide, name="acp-permission", daemon=True)
        with self._cancelled_lock:
            if request_id in self._pending_permissions:
                self._permission_workers.append(worker)
                worker.start()

    def _answer_permission(self, request_id: Any, outcome: dict[str, Any] | None) -> bool:
        """Answer a pending permission exactly once.

        Pop, re-check cancellation and send under ONE lock: deciding first and
        sending afterwards leaves a window for a cancel to arrive in between, and
        the tool is then authorised after Stop. Passing outcome=None means "only
        answer if this is already cancelled" -- it never invents an approval.
        """
        with self._cancelled_lock:
            if request_id not in self._pending_permissions:
                return False
            session_id = self._pending_permissions[request_id]
            cancelled = isinstance(session_id, str) and session_id in self._cancelled_sessions
            if cancelled:
                outcome = {"outcome": "cancelled"}
            elif outcome is None:
                return False
            del self._pending_permissions[request_id]
            try:
                self._send({"jsonrpc": "2.0", "id": request_id,
                            "result": {"outcome": outcome}})
            except (OSError, ValueError, AcpError):
                # The peer is gone. A decision thread outliving close() must not
                # raise out of a daemon worker where nobody can catch it.
                return False
            return True

    def _cancel_pending_permissions(self, session_id: str) -> None:
        """Answer every permission still waiting on a session that was cancelled."""
        with self._cancelled_lock:
            pending = [rid for rid, sid in self._pending_permissions.items()
                       if sid == session_id]
        for request_id in pending:
            self._answer_permission(request_id, {"outcome": "cancelled"})

    def request(self, method: str, params: dict[str, Any] | None = None) -> Any:
        if method in AGENT_NOTIFICATIONS:
            raise AcpError(f"{method!r} is a notification; use notify() or cancel()")
        if method not in AGENT_METHODS:
            raise AcpError(f"{method!r} is not an ACP agent method")
        request_id = self._request_id()
        message = {"jsonrpc": "2.0", "id": request_id,
                   "method": AGENT_METHODS[method], "params": params or {}}
        session_id = (params or {}).get("sessionId") if method == "session_prompt" else None
        if isinstance(session_id, str) and session_id:
            # Clearing the marker and sending the prompt is one step, for the
            # same reason cancel() is: a new turn starts uncancelled, and the
            # peer must not be told about it out of order with respect to a
            # cancel for the previous one.
            with self._cancelled_lock:
                self._cancelled_sessions.discard(session_id)
                self._send(message)
        else:
            self._send(message)
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
                # ACP v2 requires that once a client cancels, every pending
                # permission request for that session is answered `cancelled`.
                # Without this a handler could still return `selected` and
                # authorise a tool call after the user pressed Stop -- the gate
                # granting permission for work that was already abandoned.
                #
                # Deciding INLINE also meant a handler that blocks (asking a
                # person, say) held the only reader: Stop could not be answered
                # until the handler returned, so the agent waiting on this reply
                # stayed hung through the cancellation. The decision runs off the
                # pump; the pump keeps reading.
                self._begin_permission(message.get("id"), message.get("params") or {})
                continue
            if name == "elicitation_create":
                # Legion runs unattended. Declining is the honest answer; making
                # one up would put invented content into the agent's context.
                self._send({"jsonrpc": "2.0", "id": message.get("id"),
                            "result": {"action": "decline"}})
                continue
            if name == "elicitation_complete":
                # A NOTIFICATION: it carries no id. Answering it emits a response
                # with id null, which a strict peer may reject outright or
                # mis-correlate with a genuine null-id request.
                continue
        tail = "; ".join(self.stderr_tail[-3:])
        raise AcpError(
            "agent closed the connection before answering"
            + (f" (stderr: {tail})" if tail else "")
        )

    def close(self) -> None:
        """Shut the peer down without leaking a zombie, its pipes, or the caller.

        Order matters. _drain_stderr is parked inside a read on proc.stderr, so
        closing that pipe first blocks on the reader's lock and the wait() below
        is never reached -- a peer that outlives stdin then hangs close()
        forever. End the process first, which releases the reader, and only then
        close the pipes.
        """
        proc = self._proc
        if proc is None:
            return
        # Nobody is left to answer, and a worker still deciding must not try.
        with self._cancelled_lock:
            self._pending_permissions.clear()
        leader_running = proc.poll() is None
        if leader_running:
            # stdin alone is a polite request; a peer that ignores it must not
            # be able to hold the caller hostage.
            try:
                if proc.stdin is not None:
                    proc.stdin.close()
            except OSError:
                pass
            try:
                proc.wait(timeout=5)
            except subprocess.TimeoutExpired:
                self._signal_group(proc, signal.SIGTERM)
                try:
                    proc.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    self._signal_group(proc, signal.SIGKILL)
                    proc.wait()  # reap; killing alone leaves a zombie until exit
        else:
            proc.wait()
        # Sweep the group unconditionally. A leader that exited cleanly skips
        # every branch above, and its detached descendants would otherwise
        # outlive close() holding stderr open -- which is also what makes the
        # drainer join below time out.
        self._reap_group()
        # Close a stream only once the drainer has let go of it. If a descendant
        # still holds stderr open the thread cannot exit, and closing underneath
        # it would block on the buffered reader's lock -- so leave that one to
        # the garbage collector rather than hang the caller.
        drainer_finished = True
        if self._stderr_thread is not None:
            self._stderr_thread.join(timeout=5)
            drainer_finished = not self._stderr_thread.is_alive()
        closeable = [proc.stdin, proc.stdout]
        if drainer_finished:
            closeable.append(proc.stderr)
        for pipe in closeable:
            if pipe is None:
                continue
            try:
                pipe.close()
            except OSError:
                pass  # already closed, or the peer went away first
        self._proc = None

    def _reap_group(self) -> None:
        """Terminate anything left in the peer's process group."""
        if self._pgid is None:
            return
        for sig in (signal.SIGTERM, signal.SIGKILL):
            try:
                os.killpg(self._pgid, sig)
            except (ProcessLookupError, PermissionError, OSError):
                return  # nothing left in the group, or not ours to signal
            time.sleep(0.2)

    @staticmethod
    def _signal_group(proc: subprocess.Popen[bytes], sig: int) -> None:
        """Signal the peer's whole group, falling back to the process itself."""
        try:
            os.killpg(os.getpgid(proc.pid), sig)
        except (ProcessLookupError, PermissionError, OSError):
            try:
                proc.send_signal(sig)
            except (ProcessLookupError, OSError):
                pass


AGENT_TO_CLIENT_UPDATE = CLIENT_METHODS["session_update"]
_TURN_OVER = object()


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
        self._write_lock = threading.Lock()
        self._cancel_lock = threading.Lock()
        self._cancelled: set[str] = set()
        self._running: set[str] = set()

    def _write(self, message: dict[str, Any]) -> None:
        # Workers answer concurrently; interleaved partial writes would corrupt
        # the newline-delimited framing.
        with self._write_lock:
            self.stdout.write(encode(message))
            self.stdout.flush()

    def serve_forever(self) -> None:
        """Read continuously, handling requests off the reader thread.

        A session/prompt handler waits on real delegated work, so handling it
        inline blocks the loop: a session/cancel sent during that prompt is not
        even READ until the prompt has finished, and an editor's Stop button
        does nothing. Requests therefore run on worker threads while this loop
        stays free to receive cancellation.
        """
        workers: list[threading.Thread] = []
        for message in decode_stream(self.stdin):
            request_id = message.get("id")
            wire = str(message.get("method") or "")

            if not wire:
                continue  # a response to something we sent; nothing to dispatch

            name = next((k for k, v in AGENT_METHODS.items() if v == wire), None)

            if request_id is None:
                # Only genuine notifications may be dispatched without a reply.
                # A request-only method arriving without an id is malformed, and
                # running it would perform its side effects while answering
                # nobody -- session/delete is not something to do by accident.
                if name is not None and name in AGENT_NOTIFICATIONS:
                    self._dispatch_notification(name, message.get("params") or {})
                continue

            if name is None:
                self._write({"jsonrpc": "2.0", "id": request_id,
                             "error": {"code": -32601, "message": f"unsupported method: {wire}"}})
                continue

            # NOT daemon threads. A client disconnecting mid-prompt sends EOF,
            # and a daemon worker would be abandoned when the process exits --
            # taking a delegated run, its subprocesses and its worktree state
            # with it. Owned work finishes, or is cancelled deliberately.
            entered = threading.Event()
            worker = threading.Thread(
                target=self._dispatch_request,
                args=(name, message.get("params") or {}, request_id, entered),
                daemon=False,
            )
            worker.start()
            # Wait for the handler to actually ENTER before reading the next
            # message. Otherwise a cancel arriving immediately after a prompt can
            # overtake it: the handler registers its delegated run after the
            # cancel has already looked for something to cancel, and Stop is
            # silently lost while the prompt runs on.
            entered.wait(timeout=5)
            workers.append(worker)
            workers = [w for w in workers if w.is_alive()]

        # EOF: the client is gone. Tell the handler so it can unwind its own
        # delegation, then wait rather than exiting out from under it.
        self._notify_disconnect()
        for worker in workers:
            worker.join()

    def _notify_disconnect(self) -> None:
        """Cancel every prompt still running for a client that has left.

        A disconnect IS a cancellation, and it has to travel by the same route
        as an explicit one. Announcing it with no sessionId set no token, so a
        handler following the documented is_cancelled(session_id) contract never
        saw it and kept burning a delegated run whose requester was gone -- and
        a handler expecting normal cancel parameters could reject the malformed
        callback outright, leaving serve_forever waiting on work nothing would
        stop.
        """
        with self._cancel_lock:
            running = list(self._running)
            self._cancelled.update(running)
        for session_id in running:
            self._safe_handle("session_cancel",
                              {"sessionId": session_id, "reason": "client_disconnected"})
        if not running:
            # Nothing in flight, but a handler may still track its own state.
            self._safe_handle("session_cancel", {"reason": "client_disconnected"})

    def is_cancelled(self, session_id: str) -> bool:
        """Has the current prompt for this session been cancelled?

        A token, not an event. A handler registering delegated work several hops
        in -- after routing, preflight and worktree setup -- reads this when it
        is ready, so there is no window to race and no replay delay to tune. Any
        fixed delay is wrong for a run slower than the delay.
        """
        with self._cancel_lock:
            return session_id in self._cancelled

    def begin_prompt(self, session_id: str) -> None:
        """Start a turn uncancelled, discarding any marker from the last one."""
        with self._cancel_lock:
            self._cancelled.discard(session_id)
            self._running.add(session_id)

    def end_prompt(self, session_id: str) -> None:
        with self._cancel_lock:
            self._cancelled.discard(session_id)
            self._running.discard(session_id)

    def _dispatch_notification(self, name: str, params: dict[str, Any]) -> None:
        if name != "session_cancel":
            self._safe_handle(name, params)
            return
        session_id = params.get("sessionId")
        if isinstance(session_id, str) and session_id:
            with self._cancel_lock:
                self._cancelled.add(session_id)
        # Delivered once. The token above is what a handler actually relies on;
        # this notification is a courtesy for handlers that can act immediately.
        self._safe_handle(name, params)

    def emit_idle(self, session_id: Any, stop_reason: Any = None) -> None:
        """Report that foreground work has stopped, the way v2 reports it.

        A turn ends with an idle state_update carrying the stopReason -- not
        with the prompt's JSON-RPC result, which only acknowledges acceptance.
        An asynchronous handler calls this itself when its work finishes.
        """
        if not isinstance(session_id, str) or not session_id:
            return
        update: dict[str, Any] = {"sessionUpdate": "state_update", "state": "idle"}
        if stop_reason is not None:
            update["stopReason"] = stop_reason
        self._write({"jsonrpc": "2.0", "method": AGENT_TO_CLIENT_UPDATE,
                     "params": {"sessionId": session_id, "update": update}})

    def _end_prompt_for(self, params: dict[str, Any], result: Any = _TURN_OVER) -> None:
        """Release a turn only once the turn is actually over.

        ACP marks the end of a turn with a stopReason, and a v2 handler is
        allowed to ACCEPT session/prompt and return immediately while the work
        continues asynchronously. Releasing at handler-return instead tied the
        prompt's lifetime to the REQUEST's: such a session left _running while
        its run was still going, so a disconnect could not name it and the
        orphaned run carried on with nobody waiting for it.

        A handler that finishes inline reports stopReason and is released here.
        One that works asynchronously keeps the turn and calls end_prompt()
        when it is done.
        """
        if result is not _TURN_OVER and not (
                isinstance(result, dict) and "stopReason" in result):
            return
        session_id = params.get("sessionId")
        if isinstance(session_id, str) and session_id:
            self.end_prompt(session_id)

    def _safe_handle(self, name: str, params: dict[str, Any]) -> None:
        try:
            self.handler(name, params)
        except Exception:  # noqa: BLE001 - a notification has nobody to tell
            pass

    def _dispatch_request(self, name: str, params: dict[str, Any], request_id: Any,
                          entered: threading.Event | None = None) -> None:
        if name == "session_prompt":
            session_id = params.get("sessionId")
            if isinstance(session_id, str) and session_id:
                self.begin_prompt(session_id)
        if entered is not None:
            entered.set()
        try:
            result = self.handler(name, params)
        except Exception as exc:  # noqa: BLE001 - a handler fault must not kill the session
            if name == "session_prompt":
                self._end_prompt_for(params)   # a fault ends the turn outright
            self._write({"jsonrpc": "2.0", "id": request_id,
                         "error": {"code": -32603, "message": str(exc)}})
            return
        if name == "session_prompt":
            # v2 PromptResponse ACKNOWLEDGES acceptance and nothing more: the
            # schema says "This response does not indicate that the agent has
            # finished processing. Processing and completion are reported
            # through state_update session updates." Forwarding a handler's
            # stopReason as the result would be rejected by a schema-validating
            # client, which would then never learn the turn had ended. Consume
            # it here and report it the way the protocol does.
            stop_reason = result.get("stopReason") if isinstance(result, dict) else None
            self._end_prompt_for(params, result)
            ack: dict[str, Any] = {}
            if isinstance(result, dict) and isinstance(result.get("_meta"), dict):
                ack["_meta"] = result["_meta"]      # _meta is allowed on PromptResponse
            self._write({"jsonrpc": "2.0", "id": request_id, "result": ack})
            if stop_reason is not None:
                self.emit_idle(params.get("sessionId"), stop_reason)
            return
        self._write({"jsonrpc": "2.0", "id": request_id,
                     "result": {} if result is None else result})
