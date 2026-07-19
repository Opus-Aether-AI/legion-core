#!/usr/bin/env python3
"""Legion local control plane.

Fixed-verb, Unix-domain-socket control service for Legion runs. This module is
stdlib-only and importable without side effects; process signals and git
operations are exposed as module hooks for tests.
"""
from __future__ import annotations

import argparse
import datetime as _dt
import hashlib
import hmac
import json
import os
import re
import shlex
import signal
import socket
import stat
import struct
import subprocess
import sys

sys.path.insert(0, os.path.join(
    os.path.dirname(os.path.abspath(__file__)), "..", "..", "legion-observability", "scripts"))
import legion_state  # noqa: E402


VERBS = (
    "verbs.list",
    "audit.read",
    "run.kill",
    "run.cleanup",
    "diff.approve_apply",
)

AUDIT_SCHEMA = "legion.audit.v1"
RUN_ID_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$")
SHA256_RE = re.compile(r"^[0-9a-fA-F]{64}$")
MODE_RE = re.compile(r"^(?:old mode|new mode|deleted file mode|new file mode|mode) ([0-7]{6})$")
INDEX_MODE_RE = re.compile(r"^index [0-9a-fA-F]+\.\.[0-9a-fA-F]+(?: [0-7]{6})?$")
MAX_REQUEST_BYTES = 64 * 1024
# Allow the harness-neutral log root alongside the historical Claude path so the
# Console can read runs from either (deduped when they resolve to the same dir).
ALLOWED_RUN_ROOTS = tuple(dict.fromkeys((
    os.path.expanduser("~/.claude/logs/legion"),
    legion_state.default_log_root(),
)))


def _nofollow_flags():
    return getattr(os, "O_NOFOLLOW", 0) | getattr(os, "O_CLOEXEC", 0)


def _proc_info(pid):
    """Return process identity, or None if the process is not alive."""
    try:
        pid = int(pid)
        os.kill(pid, 0)
    except (TypeError, ValueError, ProcessLookupError):
        return None
    except PermissionError:
        pass
    except OSError:
        return None

    try:
        proc = subprocess.run(
            ["ps", "-p", str(pid), "-o", "uid=", "-o", "pgid=", "-o", "lstart="],
            check=False,
            capture_output=True,
            text=True,
            shell=False,
        )
        if proc.returncode != 0 or not proc.stdout.strip():
            return None
        parts = proc.stdout.strip().split(None, 2)
        if len(parts) < 2:
            return None
        return {
            "alive": True,
            "uid": int(parts[0]),
            "pgid": int(parts[1]),
            "start": parts[2] if len(parts) > 2 else "",
        }
    except (OSError, ValueError):
        return None


def _send_signal(pgid, sig):
    os.killpg(int(pgid), sig)


def _run_git(args, cwd):
    proc = subprocess.run(
        ["git"] + list(args),
        cwd=cwd,
        check=False,
        capture_output=True,
        text=True,
        shell=False,
    )
    return proc.returncode, (proc.stdout or "") + (proc.stderr or "")


def _now_uid():
    return os.getuid()


def _peer_uid(conn):
    """Peer UID of a Unix-domain socket connection, cross-platform."""
    try:
        if hasattr(socket, "SO_PEERCRED"):  # Linux
            data = conn.getsockopt(socket.SOL_SOCKET, socket.SO_PEERCRED, struct.calcsize("3i"))
            _pid, uid, _gid = struct.unpack("3i", data)
            return int(uid)
        # macOS / *BSD: LOCAL_PEERCRED returns a `struct xucred`; uid is bytes [4:8].
        # The socket module on some builds doesn't expose SOL_LOCAL/LOCAL_PEERCRED,
        # so fall back to the kernel's raw constants (SOL_LOCAL=0, LOCAL_PEERCRED=1).
        sol_local = getattr(socket, "SOL_LOCAL", 0)
        local_peercred = getattr(socket, "LOCAL_PEERCRED", 0x001)
        xucred_size = 4 + 4 + 2 + 4 * 16  # version + uid + ngroups + groups[16]
        data = conn.getsockopt(sol_local, local_peercred, xucred_size)
        if len(data) >= 8:
            _version, uid = struct.unpack("II", data[:8])
            return int(uid)
        if hasattr(socket, "getpeereid"):
            uid, _gid = socket.getpeereid(conn.fileno())
            return int(uid)
    except (AttributeError, OSError, struct.error, ValueError):
        return None
    return None


def _safe_int(value):
    try:
        return int(value)
    except (TypeError, ValueError):
        return None


def _parse_start_time(value):
    value = str(value or "").strip()
    if not value:
        return None
    try:
        parsed = _dt.datetime.fromisoformat(value.replace("Z", "+00:00"))
        return parsed if parsed.tzinfo else parsed.replace(tzinfo=_dt.timezone.utc)
    except ValueError:
        pass
    try:
        parsed = _dt.datetime.strptime(value, "%a %b %d %H:%M:%S %Y")
        return parsed.astimezone()
    except ValueError:
        return None


def _start_matches(recorded, observed):
    recorded = str(recorded or "").strip()
    observed = str(observed or "").strip()
    # Fail CLOSED for a destructive action: if we can't establish process identity
    # (either side missing/unparseable), refuse to signal. A blank started_at must
    # NOT let a reused PID/PGID pass (review finding: fail-open -> wrong-process kill).
    if not recorded or not observed:
        return False
    if recorded == observed:
        return True
    recorded_dt = _parse_start_time(recorded)
    observed_dt = _parse_start_time(observed)
    if recorded_dt and observed_dt:
        # Tight tolerance for clock skew only — NOT the old 300s PID-reuse window.
        return abs((recorded_dt - observed_dt).total_seconds()) <= 10
    return False


def _utc_now():
    return _dt.datetime.now(_dt.timezone.utc)


def _utc_ts():
    return _utc_now().isoformat().replace("+00:00", "Z")


def _valid_run_id(run_id):
    return isinstance(run_id, str) and RUN_ID_RE.fullmatch(run_id) is not None


def _arg(request, name, default=None):
    args = request.get("args")
    if isinstance(args, dict) and name in args:
        return args[name]
    return request.get(name, default)


def _bool_arg(request, name):
    value = _arg(request, name, False)
    if isinstance(value, bool):
        return value
    if isinstance(value, str):
        return value.lower() in ("1", "true", "yes", "on")
    return bool(value)


def _response(ok, verb, run_id, reason=None, **payload):
    body = {"ok": bool(ok), "verb": verb, "run_id": run_id, "reason": None if ok else reason}
    body.update(payload)
    return body


def _load_record(registry_dir, run_id):
    if not _valid_run_id(run_id):
        return None, "invalid_run_id"
    path = os.path.join(os.fspath(registry_dir), f"{run_id}.json")
    try:
        with open(path, "r", encoding="utf-8") as fh:
            record = json.load(fh)
    except FileNotFoundError:
        return None, None
    except (OSError, json.JSONDecodeError):
        return None, "invalid_record"
    if not isinstance(record, dict) or record.get("run_id") != run_id:
        return None, "invalid_record"
    return record, None


def guard_kill(record, *, confirm):
    if not isinstance(record, dict):
        return False, "missing_record"
    run_id = record.get("run_id")
    if not _valid_run_id(run_id):
        return False, "invalid_record"

    lifecycle = record.get("lifecycle") if isinstance(record.get("lifecycle"), dict) else {}
    if lifecycle.get("phase") != "running":
        return False, "not_running"
    if confirm != f"kill {run_id}":
        return False, "missing_confirm"

    process = record.get("process") if isinstance(record.get("process"), dict) else {}
    pid = _safe_int(process.get("pid"))
    pgid = _safe_int(process.get("pgid"))
    if pid is None or pid <= 0 or pgid is None or pgid <= 0:
        return False, "invalid_process"

    pi = _proc_info(pid)
    if not pi or not pi.get("alive"):
        return False, "dead_pid"
    if _safe_int(pi.get("uid")) != _now_uid():
        return False, "wrong_uid"
    if _safe_int(pi.get("pgid")) != pgid:
        return False, "pgid_mismatch"

    if not _start_matches(process.get("started_at"), pi.get("start")):
        return False, "start_mismatch"
    return True, ""


def _sha256_file(path):
    digest = hashlib.sha256()
    with open(path, "rb") as fh:
        for chunk in iter(lambda: fh.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def _split_shellish(value):
    try:
        return shlex.split(value)
    except ValueError:
        return value.split()


def _first_patch_token(value):
    tokens = _split_shellish(value.strip())
    return tokens[0] if tokens else ""


def _strip_patch_prefix(path):
    if not path or path == "/dev/null":
        return None
    if path.startswith("a/") or path.startswith("b/"):
        return path[2:]
    return path


def _validate_patch_path(raw_path):
    path = _strip_patch_prefix(raw_path)
    if path is None:
        return True, "", None
    if not path:
        return False, "unsafe_path", None
    if os.path.isabs(path) or path.startswith("/") or re.match(r"^[A-Za-z]:[\\/]", path):
        return False, "absolute_path", None

    normalized = path.replace("\\", "/")
    parts = normalized.split("/")
    if any(part in ("", ".", "..") for part in parts):
        return False, "path_traversal", None
    if any(part in (".git", ".legion") for part in parts):
        return False, "reserved_path", None
    return True, "", "/".join(parts)


def _path_prefixes(path):
    path = os.path.abspath(os.fspath(path))
    drive, rest = os.path.splitdrive(path)
    root = drive + os.sep
    rest = rest.strip(os.sep)
    prefixes = [root]
    probe = root
    for part in rest.split(os.sep):
        if not part:
            continue
        probe = os.path.join(probe, part)
        prefixes.append(probe)
    return prefixes


def _lstat_no_symlink_chain(path, *, allow_missing_leaf=False):
    prefixes = _path_prefixes(path)
    for index, probe in enumerate(prefixes):
        try:
            st = os.lstat(probe)
        except FileNotFoundError:
            if allow_missing_leaf and index == len(prefixes) - 1:
                return True, ""
            return False, "missing_path"
        except OSError:
            return False, "path_inaccessible"
        if stat.S_ISLNK(st.st_mode):
            return False, "symlink"
    return True, ""


def _is_under_or_equal(path, root):
    path = os.path.realpath(os.fspath(path))
    root = os.path.realpath(os.fspath(root))
    return path == root or path.startswith(root + os.sep)


def revalidate_targets(touched_paths, repo_root):
    repo_abs = os.path.abspath(os.fspath(repo_root))
    repo_real = os.path.realpath(repo_abs)
    ok, reason = _lstat_no_symlink_chain(repo_abs)
    if not ok:
        return False, reason
    try:
        repo_st = os.stat(repo_abs)
    except OSError:
        return False, "invalid_repo"
    if not stat.S_ISDIR(repo_st.st_mode):
        return False, "invalid_repo"

    for rel in touched_paths or []:
        if not isinstance(rel, str):
            return False, "unsafe_path"
        ok, reason, clean = _validate_patch_path(rel)
        if not ok:
            return False, reason
        if not clean:
            continue
        parts = clean.split("/")
        full = os.path.abspath(os.path.join(repo_abs, *parts))
        if full != repo_abs and not full.startswith(repo_abs + os.sep):
            return False, "path_traversal"
        ok, reason = _lstat_no_symlink_chain(full, allow_missing_leaf=True)
        if not ok:
            return False, reason
        if not _is_under_or_equal(full, repo_real):
            return False, "path_traversal"
    return True, ""


def guard_record_paths(record):
    if not isinstance(record, dict):
        return False, "invalid_record"
    repo_root = record.get("repo_root")
    run_dir = record.get("run_dir")
    if not isinstance(repo_root, str) or not isinstance(run_dir, str):
        return False, "invalid_record"

    uid = _now_uid()
    repo_abs = os.path.abspath(os.path.expanduser(repo_root))
    run_abs = os.path.abspath(os.path.expanduser(run_dir))
    for label, path in (("repo", repo_abs), ("run_dir", run_abs)):
        ok, reason = _lstat_no_symlink_chain(path)
        if not ok:
            return False, f"{label}_{reason}"
        try:
            st = os.stat(path)
        except OSError:
            return False, f"{label}_missing"
        if not stat.S_ISDIR(st.st_mode):
            return False, f"{label}_not_directory"
        if st.st_uid != uid:
            return False, f"{label}_not_owned"

    repo_real = os.path.realpath(repo_abs)
    run_real = os.path.realpath(run_abs)
    allowed_roots = [os.path.join(repo_real, ".legion")]
    allowed_roots.extend(os.path.expanduser(root) for root in ALLOWED_RUN_ROOTS)
    if not any(_is_under_or_equal(run_real, root) for root in allowed_roots):
        return False, "run_dir_outside_allowed_root"
    return True, ""


def _parse_patch_headers(patch_path, repo_root, *, allow_binary=False):
    touched = set()
    try:
        with open(patch_path, "r", encoding="utf-8", errors="replace") as fh:
            lines = fh.read().splitlines()
    except OSError:
        return False, "patch_missing", []

    for line in lines:
        if not allow_binary and (line == "GIT binary patch" or line.startswith("Binary files ")):
            return False, "binary_patch", []

        mode_match = MODE_RE.match(line.strip())
        if mode_match:
            mode = mode_match.group(1)
            if mode == "120000":
                return False, "symlink", []
            if mode == "160000":
                return False, "gitlink", []

        index_match = INDEX_MODE_RE.match(line.strip())
        if index_match:
            mode = line.strip().split()[-1] if len(line.strip().split()) >= 3 else ""
            if mode == "120000":
                return False, "symlink", []
            if mode == "160000":
                return False, "gitlink", []

        candidates = []
        if line.startswith("diff --git "):
            parts = _split_shellish(line)
            if len(parts) < 4:
                return False, "malformed_patch", []
            candidates.extend(parts[2:4])
        elif line.startswith("--- ") or line.startswith("+++ "):
            candidates.append(_first_patch_token(line[4:]))
        elif line.startswith("rename from "):
            candidates.append(line[len("rename from "):].strip())
        elif line.startswith("rename to "):
            candidates.append(line[len("rename to "):].strip())
        elif line.startswith("copy from "):
            candidates.append(line[len("copy from "):].strip())
        elif line.startswith("copy to "):
            candidates.append(line[len("copy to "):].strip())

        for raw in candidates:
            ok, reason, clean = _validate_patch_path(raw)
            if not ok:
                return False, reason, []
            if clean:
                touched.add(clean)

    if not touched:
        return False, "malformed_patch", []

    repo_abs = os.path.abspath(os.fspath(repo_root))
    for rel in touched:
        full = os.path.abspath(os.path.join(repo_abs, *rel.split("/")))
        if full != repo_abs and not full.startswith(repo_abs + os.sep):
            return False, "path_traversal", []
    return True, "", sorted(touched)


def guard_apply(patch_path, repo_root, *, expected_sha, allow_binary=False):
    patch_path = os.fspath(patch_path)
    repo_root = os.fspath(repo_root)
    if not os.path.isfile(patch_path):
        return False, "patch_missing"
    if not isinstance(expected_sha, str) or SHA256_RE.fullmatch(expected_sha) is None:
        return False, "sha_mismatch"
    actual_sha = _sha256_file(patch_path)
    if not hmac.compare_digest(actual_sha.lower(), expected_sha.lower()):
        return False, "sha_mismatch"
    if not os.path.isdir(repo_root):
        return False, "invalid_repo"

    ok, reason, _paths = _parse_patch_headers(patch_path, repo_root, allow_binary=allow_binary)
    if not ok:
        return False, reason
    ok, reason = revalidate_targets(_paths, repo_root)
    if not ok:
        return False, reason

    rc, _out = _run_git(["apply", "--check", "--index", patch_path], repo_root)
    if rc != 0:
        return False, "git_apply_check_failed"
    return True, ""


def guard_cleanup(record, *, confirm, include_running):
    if not isinstance(record, dict):
        return False, "missing_record"
    run_id = record.get("run_id")
    if not _valid_run_id(run_id):
        return False, "invalid_record"
    lifecycle = record.get("lifecycle") if isinstance(record.get("lifecycle"), dict) else {}
    running = lifecycle.get("phase") == "running"
    if running and not include_running:
        return False, "running"
    expected = f"cleanup {run_id} running" if running else f"cleanup {run_id}"
    if confirm != expected:
        return False, "missing_confirm"
    return True, ""


def _ensure_private_dir(path):
    path = os.fspath(path)
    path = os.path.abspath(os.path.expanduser(path))
    if not os.path.exists(path):
        os.makedirs(path, mode=0o700, exist_ok=True)
    try:
        st = os.lstat(path)
    except OSError:
        raise OSError("audit_dir_inaccessible")
    if stat.S_ISLNK(st.st_mode) or not stat.S_ISDIR(st.st_mode):
        raise OSError("audit_dir_not_directory")
    if st.st_uid != _now_uid():
        raise OSError("audit_dir_not_owned")
    if stat.S_IMODE(st.st_mode) != 0o700:
        raise OSError("audit_dir_bad_mode")
    return path


def _open_audit_file(path):
    try:
        st = os.lstat(path)
        if stat.S_ISLNK(st.st_mode):
            raise OSError("audit_file_symlink")
    except FileNotFoundError:
        pass
    flags = os.O_WRONLY | os.O_CREAT | os.O_APPEND | _nofollow_flags()
    fd = os.open(path, flags, 0o600)
    try:
        st = os.fstat(fd)
        if not stat.S_ISREG(st.st_mode):
            raise OSError("audit_file_not_regular")
        if st.st_uid != _now_uid():
            raise OSError("audit_file_not_owned")
        if st.st_nlink != 1:
            raise OSError("audit_file_hardlinked")
        if stat.S_IMODE(st.st_mode) != 0o600:
            raise OSError("audit_file_bad_mode")
        return fd
    except Exception:
        os.close(fd)
        raise


def _append_audit(audit_dir, *, verb, run_id, decision, reason, artifact_sha):
    audit_dir = _ensure_private_dir(audit_dir)
    path = os.path.join(audit_dir, _utc_now().strftime("%Y-%m-%d") + ".jsonl")
    entry = {
        "schema": AUDIT_SCHEMA,
        "ts": _utc_ts(),
        "verb": verb,
        "run_id": run_id,
        "decision": decision,
        "reason": reason,
        "actor_uid": _now_uid(),
        "artifact_sha": artifact_sha if artifact_sha else None,
    }
    data = (json.dumps(entry, sort_keys=True, separators=(",", ":")) + "\n").encode("utf-8")
    fd = _open_audit_file(path)
    try:
        os.write(fd, data)
    finally:
        os.close(fd)
    return entry


def _audit_or_response(audit_dir, response, *, decision, artifact_sha=None):
    try:
        _append_audit(
            audit_dir,
            verb=response.get("verb"),
            run_id=response.get("run_id"),
            decision=decision,
            reason=response.get("reason"),
            artifact_sha=artifact_sha,
        )
        return response
    except OSError:
        return _response(False, response.get("verb"), response.get("run_id"), "audit_failed")


def _audit_outcome(audit_dir, *, verb, run_id, reason, artifact_sha=None):
    try:
        _append_audit(
            audit_dir,
            verb=verb,
            run_id=run_id,
            decision="outcome",
            reason=reason,
            artifact_sha=artifact_sha,
        )
        return None
    except OSError:
        return _response(False, verb, run_id, "audit_failed")


def _check_peer_connection(conn, audit_dir):
    uid = _peer_uid(conn)
    if uid is None:
        # Fail CLOSED: if we cannot establish the peer's UID (unsupported platform or
        # a broken lookup), refuse — never serve a control verb to an unauthenticated
        # peer (review finding: peer auth must not fail open).
        resp = _response(False, "connection", None, "peer_unavailable")
        return False, _audit_or_response(audit_dir, resp, decision="reject")
    if uid != _now_uid():
        resp = _response(False, "connection", None, "peer_denied")
        return False, _audit_or_response(audit_dir, resp, decision="reject")
    return True, None


def _read_audit_entries(audit_dir, limit):
    try:
        names = sorted(name for name in os.listdir(audit_dir) if name.endswith(".jsonl"))
    except FileNotFoundError:
        return []
    entries = []
    for name in names:
        path = os.path.join(os.fspath(audit_dir), name)
        try:
            with open(path, "r", encoding="utf-8") as fh:
                for line in fh:
                    try:
                        entries.append(json.loads(line))
                    except json.JSONDecodeError:
                        continue
        except OSError:
            continue
    return entries[-limit:] if limit else []


def _artifact_sha_from_request(request):
    value = _arg(request, "sha", _arg(request, "expected_sha"))
    return value if isinstance(value, str) else None


def _final_apply_preflight(patch_path, repo_root, artifact_sha):
    ok, reason, touched_paths = _parse_patch_headers(patch_path, repo_root)
    if not ok:
        return False, reason
    ok, reason = revalidate_targets(touched_paths, repo_root)
    if not ok:
        return False, reason
    if not isinstance(artifact_sha, str):
        return False, "sha_mismatch"
    try:
        if not hmac.compare_digest(_sha256_file(patch_path).lower(), artifact_sha.lower()):
            return False, "patch_changed"
    except OSError:
        return False, "patch_missing"
    return True, ""


def _record_response_for_run(request, registry_dir, audit_dir, verb):
    run_id = request.get("run_id")
    record, load_reason = _load_record(registry_dir, run_id)
    if load_reason:
        resp = _response(False, verb, run_id, load_reason)
        return None, _audit_or_response(audit_dir, resp, decision="reject")
    if record is None:
        resp = _response(False, verb, run_id, "missing_record")
        return None, _audit_or_response(audit_dir, resp, decision="reject")
    return record, None


def handle(request, *, registry_dir, audit_dir):
    if not isinstance(request, dict):
        request = {}
    verb = request.get("verb")
    run_id = request.get("run_id")

    if verb not in VERBS:
        resp = _response(False, verb, run_id, "unknown_verb")
        return _audit_or_response(audit_dir, resp, decision="reject")

    if verb == "verbs.list":
        resp = _response(True, verb, run_id, verbs=list(VERBS))
        return _audit_or_response(audit_dir, resp, decision="accept")

    if verb == "audit.read":
        limit = _safe_int(_arg(request, "n", 100))
        if limit is None or limit < 0:
            limit = 100
        limit = min(limit, 1000)
        entries = _read_audit_entries(audit_dir, limit)
        resp = _response(True, verb, run_id, entries=entries)
        return _audit_or_response(audit_dir, resp, decision="accept")

    if verb == "run.kill":
        record, early = _record_response_for_run(request, registry_dir, audit_dir, verb)
        if early:
            return early
        ok, _path_reason = guard_record_paths(record)
        if not ok:
            resp = _response(False, verb, run_id, "untrusted_paths")
            return _audit_or_response(audit_dir, resp, decision="reject")
        confirm = _arg(request, "confirm")
        escalate = _bool_arg(request, "escalate")
        if escalate:
            if confirm != f"kill {run_id} escalate":
                resp = _response(False, verb, run_id, "missing_confirm")
                return _audit_or_response(audit_dir, resp, decision="reject")
            ok, reason = guard_kill(record, confirm=f"kill {run_id}")
            sig = signal.SIGKILL
        else:
            ok, reason = guard_kill(record, confirm=confirm)
            sig = signal.SIGTERM
        if not ok:
            resp = _response(False, verb, run_id, reason)
            return _audit_or_response(audit_dir, resp, decision="reject")

        proc = record.get("process", {}) if isinstance(record.get("process"), dict) else {}
        pgid = _safe_int(proc.get("pgid"))
        # AUTHORIZE + AUDIT only — the daemon does NOT signal. It runs every guard and
        # records the authorized decision, returning the FULL process identity the
        # executor MUST re-validate (pid/pgid/uid/started_at) before signalling, so a
        # stale/replayed authorization can't kill a reused PID. The daemon never kills.
        identity = {
            "pid": _safe_int(proc.get("pid")),
            "pgid": pgid,
            "uid": _now_uid(),
            "started_at": proc.get("started_at"),
        }
        resp = _response(True, verb, run_id, authorized=True, action="kill",
                         pgid=pgid, signal=sig.name, identity=identity,
                         note="executor MUST re-verify identity before signalling")
        return _audit_or_response(audit_dir, resp, decision="accept")

    if verb == "run.cleanup":
        record, early = _record_response_for_run(request, registry_dir, audit_dir, verb)
        if early:
            return early
        ok, _path_reason = guard_record_paths(record)
        if not ok:
            resp = _response(False, verb, run_id, "untrusted_paths")
            return _audit_or_response(audit_dir, resp, decision="reject")
        ok, reason = guard_cleanup(
            record,
            confirm=_arg(request, "confirm"),
            include_running=_bool_arg(request, "include_running"),
        )
        if not ok:
            resp = _response(False, verb, run_id, reason)
            return _audit_or_response(audit_dir, resp, decision="reject")
        argv = ["legion-delegate", "cleanup", "--run", run_id]
        resp = _response(True, verb, run_id, cleanup_argv=argv, dry_run=False)
        return _audit_or_response(audit_dir, resp, decision="accept")

    if verb == "diff.approve_apply":
        record, early = _record_response_for_run(request, registry_dir, audit_dir, verb)
        artifact_sha = _artifact_sha_from_request(request)
        if early:
            return early
        ok, _path_reason = guard_record_paths(record)
        if not ok:
            resp = _response(False, verb, run_id, "untrusted_paths")
            return _audit_or_response(audit_dir, resp, decision="reject", artifact_sha=artifact_sha)
        run_dir = record.get("run_dir")
        repo_root = record.get("repo_root")
        if not isinstance(run_dir, str) or not isinstance(repo_root, str):
            resp = _response(False, verb, run_id, "invalid_record")
            return _audit_or_response(audit_dir, resp, decision="reject", artifact_sha=artifact_sha)
        patch_path = os.path.join(run_dir, "diff.patch")
        ok, reason = guard_apply(patch_path, repo_root, expected_sha=artifact_sha)
        if not ok:
            resp = _response(False, verb, run_id, reason)
            return _audit_or_response(audit_dir, resp, decision="reject", artifact_sha=artifact_sha)
        ok, reason = _final_apply_preflight(patch_path, repo_root, artifact_sha)
        if not ok:
            resp = _response(False, verb, run_id, reason, applied=False)
            return _audit_or_response(audit_dir, resp, decision="reject", artifact_sha=artifact_sha)
        # AUTHORIZE + AUDIT only — the daemon does NOT run `git apply`. It validates the
        # patch (sha + path/symlink) and records the approval, returning the fixed argv
        # for an explicit executor: `legion-delegate apply`, which applies inside the
        # run's own isolated worktree. The daemon never writes to a live repo — this is
        # what removes the apply-TOCTOU / symlink-swap NO-GO.
        # Bind the authorization to the exact approved artifact: the executor argv
        # carries --sha, and `legion-delegate apply` MUST re-hash diff.patch and refuse
        # a mismatch. So a later swap of the patch can't ride this approval.
        apply_argv = ["legion-delegate", "apply", "--run", run_id, "--sha", artifact_sha]
        resp = _response(True, verb, run_id, authorized=True, action="apply",
                         exec_argv=apply_argv, sha=artifact_sha,
                         note="executor MUST re-verify diff.patch sha before applying")
        return _audit_or_response(audit_dir, resp, decision="accept", artifact_sha=artifact_sha)

    resp = _response(False, verb, run_id, "unknown_verb")
    return _audit_or_response(audit_dir, resp, decision="reject")


def _default_sock_path():
    return os.path.expanduser("~/.claude/legion/console.sock")


def _default_registry_dir():
    return os.path.join(legion_state.default_log_root(), "registry")


def _default_audit_dir():
    return os.path.join(legion_state.default_log_root(), "audit")


def _check_socket_dir(sock_path):
    sock_dir = os.path.dirname(os.path.abspath(os.path.expanduser(sock_path))) or "."
    if not os.path.exists(sock_dir):
        os.makedirs(sock_dir, mode=0o700)
        os.chmod(sock_dir, 0o700)
    st = os.stat(sock_dir)
    if not stat.S_ISDIR(st.st_mode):
        raise RuntimeError("socket_dir_not_directory")
    if st.st_uid != _now_uid() or stat.S_IMODE(st.st_mode) != 0o700:
        raise RuntimeError("socket_dir_not_private")
    return sock_dir


def _unlink_socket_path(sock_path, *, strict):
    try:
        st = os.lstat(sock_path)
    except FileNotFoundError:
        return
    if not stat.S_ISSOCK(st.st_mode):
        if strict:
            raise RuntimeError("socket_path_exists")
        return
    if st.st_uid != _now_uid():
        if strict:
            raise RuntimeError("socket_path_not_owned")
        return
    os.unlink(sock_path)


def _recv_limited(conn):
    chunks = []
    total = 0
    while True:
        chunk = conn.recv(4096)
        if not chunk:
            break
        total += len(chunk)
        if total > MAX_REQUEST_BYTES:
            raise ValueError("request_too_large")
        chunks.append(chunk)
    return b"".join(chunks)


def serve(sock_path, registry_dir, audit_dir):
    sock_path = os.path.abspath(os.path.expanduser(sock_path))
    _check_socket_dir(sock_path)
    _unlink_socket_path(sock_path, strict=True)

    srv = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    try:
        srv.bind(sock_path)
        os.chmod(sock_path, 0o600)
        srv.listen(16)
        while True:
            conn, _addr = srv.accept()
            with conn:
                peer_ok, peer_resp = _check_peer_connection(conn, audit_dir)
                if not peer_ok:
                    if peer_resp:
                        conn.sendall((json.dumps(peer_resp, separators=(",", ":")) + "\n").encode("utf-8"))
                    continue
                try:
                    raw = _recv_limited(conn)
                    req = json.loads(raw.decode("utf-8"))
                    resp = handle(req, registry_dir=registry_dir, audit_dir=audit_dir)
                except (UnicodeDecodeError, json.JSONDecodeError, ValueError):
                    resp = handle({"verb": None}, registry_dir=registry_dir, audit_dir=audit_dir)
                conn.sendall((json.dumps(resp, separators=(",", ":")) + "\n").encode("utf-8"))
    finally:
        srv.close()
        _unlink_socket_path(sock_path, strict=False)


def _client_request(sock_path, request):
    sock_path = os.path.abspath(os.path.expanduser(sock_path))
    data = json.dumps(request, separators=(",", ":")).encode("utf-8")
    with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as client:
        client.connect(sock_path)
        client.sendall(data)
        client.shutdown(socket.SHUT_WR)
        raw = _recv_limited(client)
    return json.loads(raw.decode("utf-8"))


def main(argv=None):
    parser = argparse.ArgumentParser(prog="legion-control")
    parser.add_argument("verb", help="fixed control verb, 'verbs', or 'serve'")
    parser.add_argument("--run", dest="run_id")
    parser.add_argument("--confirm")
    parser.add_argument("--escalate", action="store_true")
    parser.add_argument("--sha")
    parser.add_argument("--include-running", action="store_true")
    parser.add_argument("--json", action="store_true")
    parser.add_argument("--sock", default=_default_sock_path())
    parser.add_argument("--registry", default=_default_registry_dir())
    parser.add_argument("--audit", default=_default_audit_dir())
    args = parser.parse_args(argv)

    if args.verb == "serve":
        serve(args.sock, args.registry, args.audit)
        return 0

    verb = "verbs.list" if args.verb == "verbs" else args.verb
    request = {
        "verb": verb,
        "run_id": args.run_id,
        "confirm": args.confirm,
        "args": {
            "escalate": args.escalate,
            "sha": args.sha,
            "include_running": args.include_running,
        },
    }
    try:
        response = _client_request(args.sock, request)
    except OSError:
        response = _response(False, verb, args.run_id, "connect_failed")

    if not args.json and verb == "verbs.list" and response.get("ok"):
        print("\n".join(response.get("verbs", [])))
    else:
        print(json.dumps(response, sort_keys=True))
    return 0 if response.get("ok") else 1


if __name__ == "__main__":
    sys.exit(main())
