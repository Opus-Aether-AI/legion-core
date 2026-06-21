import importlib.util
import json
import os
import signal
from pathlib import Path

import pytest


HERE = os.path.dirname(__file__)
PATH = os.path.join(HERE, "..", "..", "legion-router", "scripts", "legion-control.py")


@pytest.fixture
def ctl():
    spec = importlib.util.spec_from_file_location("legion_control", PATH)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


@pytest.fixture
def tmp_path(tmp_path_factory):
    return tmp_path_factory.mktemp("legion-control").resolve()


def _record(tmp_path, *, phase="running", run_id="run-1"):
    repo = tmp_path / "repo"
    repo.mkdir(exist_ok=True)
    run_dir = repo / ".legion" / "runs" / run_id
    run_dir.mkdir(parents=True, exist_ok=True)
    return {
        "run_id": run_id,
        "repo_root": str(repo),
        "run_dir": str(run_dir),
        "worktree_dir": str(tmp_path / "worktree"),
        "branch": "legion/test",
        "lifecycle": {"phase": phase},
        "process": {
            "pid": 1234,
            "pgid": 5678,
            "started_at": "start-token",
            "host": "localhost",
        },
    }


def _write_record(registry, record):
    registry.mkdir(parents=True, exist_ok=True)
    (registry / f"{record['run_id']}.json").write_text(json.dumps(record), encoding="utf-8")


def _patch_sha(path):
    import hashlib

    return hashlib.sha256(path.read_bytes()).hexdigest()


def _write_patch(path, text):
    path.write_text(text, encoding="utf-8")
    return _patch_sha(path)


def _clean_patch():
    return """diff --git a/file.txt b/file.txt
index e69de29..ce01362 100644
--- a/file.txt
+++ b/file.txt
@@ -0,0 +1 @@
+hello
"""


def _audit_entries(audit_dir):
    entries = []
    for path in sorted(audit_dir.glob("*.jsonl")):
        entries.extend(json.loads(line) for line in path.read_text(encoding="utf-8").splitlines())
    return entries


def _secure_audit_dir(path):
    path.mkdir(parents=True, exist_ok=True)
    path.chmod(0o700)
    return path


def test_guard_kill_accepts_when_all_guards_pass(ctl, tmp_path, monkeypatch):
    record = _record(tmp_path)
    monkeypatch.setattr(
        ctl,
        "_proc_info",
        lambda pid: {"alive": True, "uid": 501, "pgid": 5678, "start": "start-token"},
    )
    monkeypatch.setattr(ctl, "_now_uid", lambda: 501)

    ok, reason = ctl.guard_kill(record, confirm="kill run-1")

    assert ok
    assert reason == ""


@pytest.mark.parametrize(
    "case,phase,confirm,proc_info,uid,reason",
    [
        (
            "dead-pid",
            "running",
            "kill run-1",
            lambda: {"alive": False, "uid": 501, "pgid": 5678, "start": "start-token"},
            501,
            "dead_pid",
        ),
        (
            "wrong-uid",
            "running",
            "kill run-1",
            lambda: {"alive": True, "uid": 502, "pgid": 5678, "start": "start-token"},
            501,
            "wrong_uid",
        ),
        (
            "pgid-mismatch",
            "running",
            "kill run-1",
            lambda: {"alive": True, "uid": 501, "pgid": 9999, "start": "start-token"},
            501,
            "pgid_mismatch",
        ),
        (
            "not-running",
            "ok",
            "kill run-1",
            lambda: {"alive": True, "uid": 501, "pgid": 5678, "start": "start-token"},
            501,
            "not_running",
        ),
        (
            "missing-confirm",
            "running",
            None,
            lambda: {"alive": True, "uid": 501, "pgid": 5678, "start": "start-token"},
            501,
            "missing_confirm",
        ),
        (
            "start-mismatch",
            "running",
            "kill run-1",
            lambda: {"alive": True, "uid": 501, "pgid": 5678, "start": "other-start"},
            501,
            "start_mismatch",
        ),
    ],
)
def test_guard_kill_rejects_failed_guards(ctl, tmp_path, monkeypatch, case, phase, confirm, proc_info, uid, reason):
    record = _record(tmp_path, phase=phase)
    monkeypatch.setattr(ctl, "_proc_info", lambda pid: proc_info())
    monkeypatch.setattr(ctl, "_now_uid", lambda: uid)

    ok, got = ctl.guard_kill(record, confirm=confirm)

    assert not ok, case
    assert got == reason


def test_guard_apply_accepts_clean_patch(ctl, tmp_path, monkeypatch):
    repo = tmp_path / "repo"
    repo.mkdir()
    patch = tmp_path / "diff.patch"
    sha = _write_patch(patch, _clean_patch())
    calls = []

    def fake_run_git(args, cwd):
        calls.append((args, cwd))
        return 0, ""

    monkeypatch.setattr(ctl, "_run_git", fake_run_git)

    ok, reason = ctl.guard_apply(patch, repo, expected_sha=sha)

    assert ok
    assert reason == ""
    assert calls == [(["apply", "--check", "--index", str(patch)], str(repo))]


@pytest.mark.parametrize(
    "name,patch_text,reason",
    [
        (
            "abs-path",
            """diff --git a/file.txt b//tmp/out
--- a/file.txt
+++ b//tmp/out
@@ -0,0 +1 @@
+bad
""",
            "absolute_path",
        ),
        (
            "dotdot",
            """diff --git a/file.txt b/../out
--- a/file.txt
+++ b/../out
@@ -0,0 +1 @@
+bad
""",
            "path_traversal",
        ),
        (
            "git-dir",
            """diff --git a/file.txt b/.git/config
--- a/file.txt
+++ b/.git/config
@@ -0,0 +1 @@
+bad
""",
            "reserved_path",
        ),
        (
            "legion-dir",
            """diff --git a/file.txt b/.legion/state
--- a/file.txt
+++ b/.legion/state
@@ -0,0 +1 @@
+bad
""",
            "reserved_path",
        ),
        (
            "symlink-mode",
            """diff --git a/link b/link
new file mode 120000
index 0000000..e69de29
--- /dev/null
+++ b/link
@@ -0,0 +1 @@
+target
""",
            "symlink",
        ),
        (
            "gitlink-mode",
            """diff --git a/sub b/sub
new file mode 160000
index 0000000..e69de29
--- /dev/null
+++ b/sub
@@ -0,0 +1 @@
+submodule
""",
            "gitlink",
        ),
        (
            "binary",
            """diff --git a/blob.bin b/blob.bin
GIT binary patch
literal 0
HcmV?d00001
""",
            "binary_patch",
        ),
    ],
)
def test_guard_apply_rejects_unsafe_patch_before_git(ctl, tmp_path, monkeypatch, name, patch_text, reason):
    repo = tmp_path / "repo"
    repo.mkdir()
    patch = tmp_path / "diff.patch"
    sha = _write_patch(patch, patch_text)
    calls = []
    monkeypatch.setattr(ctl, "_run_git", lambda args, cwd: calls.append((args, cwd)) or (0, ""))

    ok, got = ctl.guard_apply(patch, repo, expected_sha=sha)

    assert not ok, name
    assert got == reason
    assert calls == []


def test_guard_apply_rejects_sha_mismatch_without_git(ctl, tmp_path, monkeypatch):
    repo = tmp_path / "repo"
    repo.mkdir()
    patch = tmp_path / "diff.patch"
    _write_patch(patch, _clean_patch())
    calls = []
    monkeypatch.setattr(ctl, "_run_git", lambda args, cwd: calls.append((args, cwd)) or (0, ""))

    ok, reason = ctl.guard_apply(patch, repo, expected_sha="0" * 64)

    assert not ok
    assert reason == "sha_mismatch"
    assert calls == []


def test_guard_apply_rejects_git_apply_check_failure(ctl, tmp_path, monkeypatch):
    repo = tmp_path / "repo"
    repo.mkdir()
    patch = tmp_path / "diff.patch"
    sha = _write_patch(patch, _clean_patch())
    calls = []

    def fake_run_git(args, cwd):
        calls.append((args, cwd))
        return 1, "nope"

    monkeypatch.setattr(ctl, "_run_git", fake_run_git)

    ok, reason = ctl.guard_apply(patch, repo, expected_sha=sha)

    assert not ok
    assert reason == "git_apply_check_failed"
    assert calls == [(["apply", "--check", "--index", str(patch)], str(repo))]


def test_handle_unknown_verb_rejects_and_audits(ctl, tmp_path, monkeypatch):
    registry = tmp_path / "registry"
    audit = tmp_path / "audit"
    monkeypatch.setattr(ctl, "_send_signal", lambda pgid, sig: pytest.fail("signal called"))
    monkeypatch.setattr(ctl, "_run_git", lambda args, cwd: pytest.fail("git called"))
    monkeypatch.setattr(ctl, "_now_uid", lambda: os.getuid())

    resp = ctl.handle({"verb": "shell.exec", "run_id": "run-1", "confirm": "secret"}, registry_dir=registry, audit_dir=audit)

    assert resp["ok"] is False
    assert resp["reason"] == "unknown_verb"
    entries = _audit_entries(audit)
    assert entries[-1]["decision"] == "reject"
    assert entries[-1]["verb"] == "shell.exec"
    assert "secret" not in json.dumps(entries[-1])


def test_handle_run_kill_without_confirm_rejects_without_signal(ctl, tmp_path, monkeypatch):
    registry = tmp_path / "registry"
    audit = tmp_path / "audit"
    record = _record(tmp_path)
    _write_record(registry, record)
    sent = []
    uid = os.getuid()
    monkeypatch.setattr(ctl, "_send_signal", lambda pgid, sig: sent.append((pgid, sig)))
    monkeypatch.setattr(
        ctl,
        "_proc_info",
        lambda pid: {"alive": True, "uid": uid, "pgid": 5678, "start": "start-token"},
    )
    monkeypatch.setattr(ctl, "_now_uid", lambda: uid)

    resp = ctl.handle({"verb": "run.kill", "run_id": "run-1"}, registry_dir=registry, audit_dir=audit)

    assert resp["ok"] is False
    assert resp["reason"] == "missing_confirm"
    assert sent == []
    assert _audit_entries(audit)[-1]["decision"] == "reject"


def test_handle_run_kill_authorizes_and_audits_but_does_NOT_signal(ctl, tmp_path, monkeypatch):
    # Authorize-and-audit model: all guards pass -> authorized=True + the action,
    # but the daemon must NOT signal (execution is a separate explicit step).
    registry = tmp_path / "registry"
    audit = tmp_path / "audit"
    record = _record(tmp_path)
    _write_record(registry, record)
    sent = []
    uid = os.getuid()
    monkeypatch.setattr(
        ctl,
        "_proc_info",
        lambda pid: {"alive": True, "uid": uid, "pgid": 5678, "start": "start-token"},
    )
    monkeypatch.setattr(ctl, "_now_uid", lambda: uid)
    monkeypatch.setattr(ctl, "_send_signal", lambda pgid, sig: sent.append((pgid, sig)))

    resp = ctl.handle(
        {"verb": "run.kill", "run_id": "run-1", "confirm": "kill run-1"},
        registry_dir=registry,
        audit_dir=audit,
    )

    assert resp["ok"] is True
    assert resp["authorized"] is True
    assert resp["action"] == "kill" and resp["signal"] == "SIGTERM"
    assert sent == []   # the daemon did NOT signal — it only authorized + audited
    assert _audit_entries(audit)[-1]["decision"] == "accept"


def test_handle_audit_read_returns_written_entries(ctl, tmp_path, monkeypatch):
    audit = tmp_path / "audit"
    registry = tmp_path / "registry"
    _secure_audit_dir(audit)
    entry = {
        "schema": "legion.audit.v1",
        "ts": "2026-06-15T00:00:00Z",
        "verb": "run.kill",
        "run_id": "run-1",
        "decision": "reject",
        "reason": "missing_confirm",
        "actor_uid": 501,
        "artifact_sha": None,
    }
    path = audit / "2026-06-15.jsonl"
    path.write_text(json.dumps(entry) + "\n", encoding="utf-8")
    path.chmod(0o600)
    monkeypatch.setattr(ctl, "_now_uid", lambda: os.getuid())

    resp = ctl.handle({"verb": "audit.read", "args": {"n": 10}}, registry_dir=registry, audit_dir=audit)

    assert resp["ok"] is True
    assert entry in resp["entries"]


def test_handle_diff_apply_rejects_on_toctou_sha_change(ctl, tmp_path, monkeypatch):
    # The guard validates the patch sha; if the file is swapped between the guard and
    # the apply, the re-check must catch it and NOT run `git apply --index`.
    registry = tmp_path / "registry"
    audit = tmp_path / "audit"
    record = _record(tmp_path)
    patch = os.path.join(record["run_dir"], "diff.patch")
    with open(patch, "w", encoding="utf-8") as fh:
        fh.write(_clean_patch())
    _write_record(registry, record)
    git_calls = []
    monkeypatch.setattr(ctl, "_run_git", lambda args, cwd: git_calls.append(args) or (0, ""))
    monkeypatch.setattr(ctl, "_now_uid", lambda: os.getuid())
    expected = "a" * 64
    seen = {"n": 0}

    def fake_sha(_path):  # call 1 = guard (matches); call 2 = TOCTOU re-check (changed)
        seen["n"] += 1
        return expected if seen["n"] == 1 else "b" * 64

    monkeypatch.setattr(ctl, "_sha256_file", fake_sha)

    resp = ctl.handle(
        {"verb": "diff.approve_apply", "run_id": "run-1", "args": {"sha": expected}},
        registry_dir=registry,
        audit_dir=audit,
    )

    assert resp["ok"] is False
    assert resp["reason"] == "patch_changed"
    assert ["apply", "--index", patch] not in git_calls   # the real apply never ran
    assert _audit_entries(audit)[-1]["decision"] == "reject"


def test_guard_kill_fails_closed_when_start_time_missing(ctl, tmp_path, monkeypatch):
    # GPT-5.5 verify: a blank started_at must NOT let a reused PID/PGID pass.
    rec = _record(tmp_path)
    rec["process"]["started_at"] = ""
    monkeypatch.setattr(
        ctl, "_proc_info",
        lambda pid: {"alive": True, "uid": 501, "pgid": 5678, "start": "real-start"},
    )
    monkeypatch.setattr(ctl, "_now_uid", lambda: 501)
    ok, reason = ctl.guard_kill(rec, confirm="kill run-1")
    assert ok is False and reason == "start_mismatch"


def test_guard_apply_rejects_parent_directory_symlink(ctl, tmp_path, monkeypatch):
    # GPT-5.5 verify: a symlink on a PARENT component (not just the leaf) must reject.
    repo = tmp_path / "repo"
    repo.mkdir()
    outside = tmp_path / "outside"
    outside.mkdir()
    (repo / "linkdir").symlink_to(outside, target_is_directory=True)
    patch = tmp_path / "p.patch"
    sha = _write_patch(
        patch,
        "diff --git a/linkdir/f.txt b/linkdir/f.txt\n"
        "index e69de29..ce01362 100644\n"
        "--- a/linkdir/f.txt\n"
        "+++ b/linkdir/f.txt\n"
        "@@ -0,0 +1 @@\n+x\n",
    )
    monkeypatch.setattr(ctl, "_run_git", lambda a, c: (0, ""))
    ok, reason = ctl.guard_apply(str(patch), str(repo), expected_sha=sha)
    assert ok is False and reason == "symlink"


def test_handle_verbs_list_returns_enum(ctl, tmp_path, monkeypatch):
    monkeypatch.setattr(ctl, "_now_uid", lambda: os.getuid())

    resp = ctl.handle({"verb": "verbs.list"}, registry_dir=tmp_path / "registry", audit_dir=tmp_path / "audit")

    assert resp["ok"] is True
    assert resp["verbs"] == list(ctl.VERBS)


def test_handle_rejected_diff_does_not_call_git(ctl, tmp_path, monkeypatch):
    registry = tmp_path / "registry"
    audit = tmp_path / "audit"
    record = _record(tmp_path)
    patch = os.path.join(record["run_dir"], "diff.patch")
    with open(patch, "w", encoding="utf-8") as fh:
        fh.write(_clean_patch())
    _write_record(registry, record)
    calls = []
    monkeypatch.setattr(ctl, "_run_git", lambda args, cwd: calls.append((args, cwd)) or (0, ""))
    monkeypatch.setattr(ctl, "_now_uid", lambda: os.getuid())

    resp = ctl.handle(
        {"verb": "diff.approve_apply", "run_id": "run-1", "args": {"sha": "0" * 64}},
        registry_dir=registry,
        audit_dir=audit,
    )

    assert resp["ok"] is False
    assert resp["reason"] == "sha_mismatch"
    assert calls == []
    assert _audit_entries(audit)[-1]["decision"] == "reject"


def test_handle_diff_apply_rejects_parent_swapped_to_symlink_before_apply(ctl, tmp_path, monkeypatch):
    registry = tmp_path / "registry"
    audit = tmp_path / "audit"
    record = _record(tmp_path)
    target_dir = tmp_path / "repo" / "safe"
    target_dir.mkdir()
    outside = tmp_path / "outside"
    outside.mkdir()
    patch = os.path.join(record["run_dir"], "diff.patch")
    sha = _write_patch(
        Path(patch),
        "diff --git a/safe/file.txt b/safe/file.txt\n"
        "index e69de29..ce01362 100644\n"
        "--- a/safe/file.txt\n"
        "+++ b/safe/file.txt\n"
        "@@ -0,0 +1 @@\n+x\n",
    )
    _write_record(registry, record)
    calls = []

    def fake_run_git(args, cwd):
        calls.append(args)
        if args[:3] == ["apply", "--check", "--index"]:
            target_dir.rmdir()
            target_dir.symlink_to(outside, target_is_directory=True)
            return 0, ""
        if args[:2] == ["apply", "--index"]:
            pytest.fail("git apply --index must not run after symlink swap")
        return 0, ""

    monkeypatch.setattr(ctl, "_run_git", fake_run_git)
    monkeypatch.setattr(ctl, "_now_uid", lambda: os.getuid())

    resp = ctl.handle(
        {"verb": "diff.approve_apply", "run_id": "run-1", "args": {"sha": sha}},
        registry_dir=registry,
        audit_dir=audit,
    )

    assert resp["ok"] is False
    assert resp["reason"] == "symlink"
    assert ["apply", "--index", patch] not in calls
    entries = _audit_entries(audit)
    assert entries[-1]["decision"] == "reject"
    assert entries[-1]["reason"] == "symlink"


def test_guard_record_paths_accepts_clean_run_dir_under_repo_legion(ctl, tmp_path, monkeypatch):
    record = _record(tmp_path)
    monkeypatch.setattr(ctl, "_now_uid", lambda: os.getuid())

    ok, reason = ctl.guard_record_paths(record)

    assert ok is True
    assert reason == ""


def test_guard_record_paths_rejects_not_owned_paths(ctl, tmp_path, monkeypatch):
    record = _record(tmp_path)
    monkeypatch.setattr(ctl, "_now_uid", lambda: os.getuid() + 1)

    ok, reason = ctl.guard_record_paths(record)

    assert ok is False
    assert reason == "repo_not_owned"


def test_guard_record_paths_rejects_symlinked_repo_root(ctl, tmp_path, monkeypatch):
    real_repo = tmp_path / "real-repo"
    run_dir = real_repo / ".legion" / "runs" / "run-1"
    run_dir.mkdir(parents=True)
    repo_link = tmp_path / "repo-link"
    repo_link.symlink_to(real_repo, target_is_directory=True)
    record = {
        "run_id": "run-1",
        "repo_root": str(repo_link),
        "run_dir": str(repo_link / ".legion" / "runs" / "run-1"),
    }
    monkeypatch.setattr(ctl, "_now_uid", lambda: os.getuid())

    ok, reason = ctl.guard_record_paths(record)

    assert ok is False
    assert reason == "repo_symlink"


def test_guard_record_paths_rejects_run_dir_outside_allowed_roots(ctl, tmp_path, monkeypatch):
    record = _record(tmp_path)
    outside = tmp_path / "outside-run"
    outside.mkdir()
    record["run_dir"] = str(outside)
    monkeypatch.setattr(ctl, "_now_uid", lambda: os.getuid())

    ok, reason = ctl.guard_record_paths(record)

    assert ok is False
    assert reason == "run_dir_outside_allowed_root"


def test_append_audit_refuses_preexisting_symlink_file(ctl, tmp_path, monkeypatch):
    audit = _secure_audit_dir(tmp_path / "audit")
    target = tmp_path / "target.jsonl"
    target.write_text("", encoding="utf-8")
    target.chmod(0o600)
    (audit / "2026-06-15.jsonl").symlink_to(target)
    monkeypatch.setattr(
        ctl,
        "_utc_now",
        lambda: ctl._dt.datetime(2026, 6, 15, tzinfo=ctl._dt.timezone.utc),
    )
    monkeypatch.setattr(ctl, "_now_uid", lambda: os.getuid())

    with pytest.raises(OSError):
        ctl._append_audit(
            audit,
            verb="run.kill",
            run_id="run-1",
            decision="reject",
            reason="test",
            artifact_sha=None,
        )


def test_append_audit_refuses_hardlinked_file(ctl, tmp_path, monkeypatch):
    audit = _secure_audit_dir(tmp_path / "audit")
    original = tmp_path / "original.jsonl"
    original.write_text("", encoding="utf-8")
    original.chmod(0o600)
    try:
        os.link(original, audit / "2026-06-15.jsonl")
    except OSError:
        pytest.skip("hardlinks unavailable on this filesystem")
    monkeypatch.setattr(
        ctl,
        "_utc_now",
        lambda: ctl._dt.datetime(2026, 6, 15, tzinfo=ctl._dt.timezone.utc),
    )
    monkeypatch.setattr(ctl, "_now_uid", lambda: os.getuid())

    with pytest.raises(OSError, match="audit_file_hardlinked"):
        ctl._append_audit(
            audit,
            verb="run.kill",
            run_id="run-1",
            decision="reject",
            reason="test",
            artifact_sha=None,
        )


def test_peer_uid_mismatch_is_refused_and_audited(ctl, tmp_path, monkeypatch):
    audit = tmp_path / "audit"
    monkeypatch.setattr(ctl, "_peer_uid", lambda conn: os.getuid() + 1)
    monkeypatch.setattr(ctl, "_now_uid", lambda: os.getuid())

    ok, resp = ctl._check_peer_connection(object(), audit)

    assert ok is False
    assert resp["reason"] == "peer_denied"
    entries = _audit_entries(audit)
    assert entries[-1]["decision"] == "reject"
    assert entries[-1]["reason"] == "peer_denied"


def test_handle_diff_apply_authorizes_but_never_runs_git_apply_index(ctl, tmp_path, monkeypatch):
    # Authorize-and-audit model: the daemon validates (git apply --check, in the guard)
    # and returns the executor argv, but NEVER runs `git apply --index` itself.
    registry = tmp_path / "registry"
    audit = tmp_path / "audit"
    record = _record(tmp_path)
    patch = os.path.join(record["run_dir"], "diff.patch")
    sha = _write_patch(Path(patch), _clean_patch())
    _write_record(registry, record)
    calls = []
    monkeypatch.setattr(ctl, "_run_git", lambda args, cwd: calls.append(args) or (0, ""))
    monkeypatch.setattr(ctl, "_now_uid", lambda: os.getuid())

    resp = ctl.handle(
        {"verb": "diff.approve_apply", "run_id": "run-1", "args": {"sha": sha}},
        registry_dir=registry,
        audit_dir=audit,
    )

    assert resp["ok"] is True
    assert resp["authorized"] is True
    # argv is BOUND to the approved sha (executor must re-verify it)
    assert resp["exec_argv"] == ["legion-delegate", "apply", "--run", "run-1", "--sha", sha]
    assert ["apply", "--index", patch] not in calls   # daemon validated, did NOT apply
    assert _audit_entries(audit)[-1]["decision"] == "accept"
