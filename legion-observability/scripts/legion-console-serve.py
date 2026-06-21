#!/usr/bin/env python3
"""legion-console-serve — minimal local dashboard server for the Legion Console.

Dev/standalone form of the Phase 1 read path: serves the single-page console +
the indexer snapshot over HTTP + SSE, loopback-only, stdlib only (no build step).
The Bun-router integration (`/console/*` on :8082) is the productionization; this
is the "see it now" server.

  legion-console-serve [--host 127.0.0.1] [--port 8090] [--interval 1.5]
                       [--registry DIR] [--spans DIR]
"""
from __future__ import annotations

import argparse
import importlib.util
import json
import os
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

_HERE = os.path.dirname(os.path.abspath(__file__))


def _load_indexer():
    spec = importlib.util.spec_from_file_location(
        "legion_console_index", os.path.join(_HERE, "legion-console-index.py"))
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


def _load_module(filename, modname):
    spec = importlib.util.spec_from_file_location(modname, os.path.join(_HERE, filename))
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


def _load_path(path, modname):
    spec = importlib.util.spec_from_file_location(modname, path)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


IDX = _load_indexer()
CAT = _load_module("legion-catalog.py", "legion_catalog")
ACT = _load_module("legion-activity.py", "legion_activity")
HTML_PATH = os.path.join(_HERE, "..", "ui", "console.html")

CFG = {"registry": None, "spans": None, "interval": 1.5, "repo": None,
       "control_sock": os.path.expanduser("~/.claude/legion/console.sock")}
CTRL = None  # lazy-loaded legion-control client (it lives in legion-router/scripts)


def _repo() -> str:
    return CFG.get("repo") or os.path.abspath(os.path.join(_HERE, "..", ".."))


def _ctrl():
    global CTRL
    if CTRL is None:
        CTRL = _load_path(
            os.path.join(_repo(), "legion-router", "scripts", "legion-control.py"),
            "legion_control")
    return CTRL


# Allow-list mirrors the daemon's verb enum: the dashboard can only forward THESE.
CONTROL_VERBS = {"verbs.list", "audit.read", "run.kill", "run.cleanup", "diff.approve_apply"}


def control(req: dict) -> dict:
    # Forward a control request to the AUTHORIZE-AND-AUDIT daemon over its UDS. The
    # daemon validates + audits + returns the authorized action (it never executes).
    verb = (req or {}).get("verb")
    if verb not in CONTROL_VERBS:
        return {"ok": False, "verb": verb, "reason": "unknown_verb"}
    try:
        request = {"verb": verb, "run_id": req.get("run_id"), "confirm": req.get("confirm"),
                   "args": {"sha": req.get("sha"), "escalate": bool(req.get("escalate")),
                            "include_running": bool(req.get("include_running"))}}
        return _ctrl()._client_request(CFG["control_sock"], request)
    except (OSError, ConnectionError) as exc:
        return {"ok": False, "verb": verb, "reason": "control_plane_unreachable",
                "detail": f"start it: legion-control serve  ({exc})"}
    except Exception as exc:  # noqa: BLE001
        return {"ok": False, "verb": verb, "reason": "control_error", "detail": str(exc)}


def snapshot() -> dict:
    return IDX.build_snapshot(CFG["registry"], CFG["spans"])


def activity() -> dict:
    # Per-agent activity (tools/files) + real per-run cost + session grouping. Best-effort.
    try:
        return ACT.build_activity(
            CFG["registry"],
            os.path.join(_repo(), ".legion", "runs"),
            os.path.join(_repo(), "legion-router", "config", "costs.json"),
        )
    except Exception as exc:  # noqa: BLE001 - dashboard must never 500
        return {"error": str(exc), "runs": [], "sessions": [], "totals": {}}


def catalog() -> dict:
    # Marketplace inventory (plugins/skills/agents/commands/hooks/MCPs). Best-effort.
    try:
        return CAT.build_catalog(_repo())
    except Exception as exc:  # noqa: BLE001 - dashboard must never 500 on inventory
        return {"error": str(exc), "by_type": {}, "entities": []}


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *_args):  # quiet
        pass

    def _send(self, code, body, ctype="application/json"):
        data = body.encode() if isinstance(body, str) else body
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(data)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(data)

    def do_GET(self):
        if self.path in ("/", "/index.html"):
            try:
                with open(HTML_PATH, "rb") as fh:
                    self._send(200, fh.read(), "text/html; charset=utf-8")
            except OSError:
                self._send(500, "console.html not found")
            return
        if self.path.startswith("/console/snapshot"):
            self._send(200, json.dumps(snapshot()))
            return
        if self.path.startswith("/console/activity"):
            self._send(200, json.dumps(activity()))
            return
        if self.path.startswith("/console/catalog"):
            self._send(200, json.dumps(catalog()))
            return
        if self.path.startswith("/console/events"):
            self.send_response(200)
            self.send_header("Content-Type", "text/event-stream")
            self.send_header("Cache-Control", "no-store")
            self.send_header("Connection", "keep-alive")
            self.end_headers()
            try:
                while True:
                    payload = json.dumps(snapshot())
                    self.wfile.write(f"data: {payload}\n\n".encode())
                    self.wfile.flush()
                    time.sleep(CFG["interval"])
            except (BrokenPipeError, ConnectionResetError):
                return
            return
        self._send(404, "not found")

    def do_POST(self):
        if not self.path.startswith("/console/control"):
            self._send(404, "not found")
            return
        # Same-origin guard: reject cross-site POSTs (no permissive CORS).
        origin = self.headers.get("Origin")
        host = self.headers.get("Host", "")
        if origin and origin not in (f"http://{host}", f"https://{host}"):
            self._send(403, json.dumps({"ok": False, "reason": "bad_origin"}))
            return
        try:
            length = int(self.headers.get("Content-Length", 0))
            req = json.loads(self.rfile.read(length) or b"{}")
        except (ValueError, OSError):
            self._send(400, json.dumps({"ok": False, "reason": "bad_request"}))
            return
        self._send(200, json.dumps(control(req)))


def main(argv=None):
    ap = argparse.ArgumentParser(prog="legion-console-serve")
    ap.add_argument("--host", default="127.0.0.1")
    ap.add_argument("--port", type=int, default=8090)
    ap.add_argument("--interval", type=float, default=1.5)
    ap.add_argument("--registry", default=os.path.expanduser("~/.claude/logs/legion/registry"))
    ap.add_argument("--spans", default=os.path.expanduser("~/.claude/logs/legion/spans"))
    ap.add_argument("--repo", default=os.path.abspath(os.path.join(_HERE, "..", "..")),
                    help="marketplace repo root for the inventory catalog")
    ap.add_argument("--control-sock", default=os.path.expanduser("~/.claude/legion/console.sock"),
                    help="legion-control daemon socket (for steer actions)")
    args = ap.parse_args(argv)
    CFG["control_sock"] = args.control_sock
    CFG.update(registry=args.registry, spans=args.spans, interval=args.interval, repo=args.repo)
    srv = ThreadingHTTPServer((args.host, args.port), Handler)
    print(f"Legion Console → http://{args.host}:{args.port}  (loopback only; Ctrl-C to stop)")
    try:
        srv.serve_forever()
    except KeyboardInterrupt:
        srv.shutdown()


if __name__ == "__main__":
    main()
