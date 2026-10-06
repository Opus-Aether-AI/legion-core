import importlib.util
import json
import os
import subprocess

HERE = os.path.dirname(__file__)
ROOT = os.path.abspath(os.path.join(HERE, "..", ".."))
_PATH = os.path.join(ROOT, "legion-orchestrate", "scripts", "legion-doc-check.py")
_spec = importlib.util.spec_from_file_location("legion_doc_check", _PATH)
dc = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(dc)


def write(root, rel, text):
    path = root / rel
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(text, encoding="utf-8")
    return path


def run(root, *args):
    return dc.check(root, dict(dc.DEFAULTS, **dict(args)))


def test_clean_outward_documents_pass(tmp_path):
    write(tmp_path, "out/plan.md", "# Plan\n\nRevenue reaches USD 12M in year 3 (target).\n")
    report = run(tmp_path, ("publish", ["out/**/*.md"]))
    assert report["ok"] and report["findings"] == [] and report["checks"]["markers"]["files"] == 1


def test_open_markers_and_unresolved_tokens_block(tmp_path):
    write(tmp_path, "out/plan.md", "Proof: [PROOF NEEDED: signed letter]\nTotal {=totals.y3}; owner TBD\n")
    report = run(tmp_path, ("publish", ["out/*.md"]))
    assert not report["ok"]
    found = {(f["check"], f["line"], f["match"]) for f in report["findings"]}
    assert ("markers", 1, "[PROOF NEEDED: signed letter]") in found
    assert ("tokens", 2, "{=totals.y3}") in found
    assert ("markers", 2, "TBD") in found
    ids = {item["id"] for item in report["learning_feedback"]}
    assert ids == {"doc-check-markers", "doc-check-tokens"}


def test_deny_patterns_catch_confidential_terms_in_outward_files_only(tmp_path):
    write(tmp_path, "out/pitch.md", "Our founders' salaries are not shown here.\n")
    write(tmp_path, "internal/pay.md", "Founder salary: confidential.\n")
    deny = [{"category": "pay", "pattern": r"(?i)\bsalar(y|ies)\b"}]
    report = run(tmp_path, ("publish", ["out/*.md"]), ("deny", deny))
    assert not report["ok"]
    assert [(f["check"], f["file"], f["pattern"]) for f in report["findings"]] == [("deny", "out/pitch.md", "pay")]


def test_superseded_records_must_name_their_successor(tmp_path):
    write(tmp_path, "records/old-plan.md", "# Old plan\n\n> Superseded on 5 October.\n\nBody.\n")
    write(tmp_path, "records/old-model.md", "# Model v3\n\n> Superseded by [the v5 model](../v5/README.md).\n")
    write(tmp_path, "records/notes.md", "# Notes\n\nIntro.\n\nMore.\n\nA later section mentions a superseded idea.\n")
    report = run(tmp_path, ("records", ["records/*.md"]), ("head_lines", 4))
    assert [(f["file"], f["line"]) for f in report["findings"]] == [("records/old-plan.md", 3)]
    assert report["checks"]["supersession"]["files"] == 3


def test_advisory_checks_report_without_failing(tmp_path):
    write(tmp_path, "records/old.md", "> Superseded.\n")
    report = run(tmp_path, ("records", ["records/*.md"]), ("advisory", ["supersession"]))
    assert report["ok"] and len(report["findings"]) == 1 and report["findings"][0]["blocking"] is False


def test_an_unreadable_outward_file_is_never_reported_clean(tmp_path, monkeypatch):
    write(tmp_path, "out/deck.pdf", "%PDF-1.4 not really a pdf")
    monkeypatch.setattr(dc.shutil, "which", lambda name: None)
    report = run(tmp_path, ("publish", ["out/*.pdf"]))
    assert not report["ok"] and "pdftotext is not installed" in report["unchecked"][0]


def test_a_glob_that_matches_nothing_is_never_reported_clean(tmp_path):
    write(tmp_path, "content/plan.md", "All sourced.\n")
    report = run(tmp_path, ("publish", ["content/*.md", "dist/**/*.pdf"]))
    assert not report["ok"] and report["empty_globs"] == ["--publish 'dist/**/*.pdf'"]
    assert "matched no files" in report["unchecked"][0]
    assert any(item["id"] == "doc-check-unchecked" for item in report["learning_feedback"])
    allowed = run(tmp_path, ("publish", ["content/*.md", "dist/**/*.pdf"]), ("allow_empty", True))
    assert allowed["ok"] and allowed["empty_globs"] == ["--publish 'dist/**/*.pdf'"]


def test_unreadable_records_and_textless_pdfs_are_unchecked(tmp_path, monkeypatch):
    write(tmp_path, "records/old.docx", "binary")
    report = run(tmp_path, ("records", ["records/*"]))
    assert not report["ok"] and "unsupported file type .docx" in report["unchecked"][0]
    locked = write(tmp_path, "records/locked.md", "> Superseded.\n")
    locked.chmod(0)
    try:
        report = run(tmp_path, ("records", ["records/locked.md"]))
    finally:
        locked.chmod(0o644)
    assert not report["ok"] and "cannot read" in report["unchecked"][0]
    write(tmp_path, "out/scan.pdf", "%PDF-1.4 image only")
    monkeypatch.setattr(dc.shutil, "which", lambda name: "/usr/bin/pdftotext")
    monkeypatch.setattr(dc.subprocess, "run", lambda *a, **k: dc.subprocess.CompletedProcess(a, 0, stdout="  \n", stderr=""))
    report = run(tmp_path, ("publish", ["out/*.pdf"]))
    assert not report["ok"] and "no text" in report["unchecked"][0]


def test_the_successor_must_be_named_near_the_superseded_line(tmp_path):
    write(tmp_path, "records/a.md", "# A\n\n> Superseded on 5 October.\n\n\nSee [sources](sources.md).\n")
    write(tmp_path, "records/b.md", "# B\n\n> Superseded on 5 October,\n> by [the new plan](plan.md).\n")
    report = run(tmp_path, ("records", ["records/*.md"]))
    assert [(f["file"], f["line"]) for f in report["findings"]] == [("records/a.md", 3)]


def test_config_values_are_type_checked_and_patterns_compiled(tmp_path):
    bad = [{"publish": "out/deck.md"}, {"publish": ["out/*.md"], "markers": ["[unclosed"]},
           {"publish": ["out/*.md"], "head_lines": "15"}, {"publish": ["out/*.md"], "deny": ["salary"]},
           {"publish": ["out/*.md"], "advisory": ["spelling"]}, {"publish": ["out/*.md"], "allow_empty": "yes"},
           {"publish": ["out/*.md"], "markers": [], "tokens": []}, {"publish": ["out/*.md"], "deny": [{"category": "", "pattern": "x"}]}]
    command = [os.path.join(ROOT, "legion-orchestrate", "bin", "legion-doc-check"), "--repo", str(tmp_path)]
    for index, config in enumerate(bad):
        path = write(tmp_path, f"bad-{index}.json", json.dumps(config))
        done = subprocess.run(command + ["--config", str(path)], capture_output=True, text=True, check=False)
        assert done.returncode == 2 and json.loads(done.stderr)["ok"] is False, config
    empty_category = subprocess.run(command + ["--publish", "out/*.md", "--deny", "=(?i)salary"], capture_output=True, text=True, check=False)
    assert empty_category.returncode == 2


def test_config_rejects_unknown_keys(tmp_path):
    config = write(tmp_path, "doc-check.json", json.dumps({"publsh": ["out/*.md"]}))
    try:
        dc.load_config(str(config))
    except ValueError as error:
        assert "publsh" in str(error)
    else:
        raise AssertionError("a misspelled key must be an error")


def test_cli_exit_codes_and_json_report(tmp_path):
    write(tmp_path, "out/a.md", "All sourced.\n")
    command = [os.path.join(ROOT, "legion-orchestrate", "bin", "legion-doc-check"), "--repo", str(tmp_path)]
    clean = subprocess.run(command + ["--publish", "out/*.md"], capture_output=True, text=True, check=False)
    assert clean.returncode == 0 and json.loads(clean.stdout)["ok"] is True
    write(tmp_path, "out/b.md", "[DETAIL NEEDED: owner]\n")
    dirty = subprocess.run(command + ["--publish", "out/*.md", "--name", "pitch"], capture_output=True, text=True, check=False)
    report = json.loads(dirty.stdout)
    assert dirty.returncode == 1 and report["learning_feedback"][0]["target_name"] == "pitch"
    usage = subprocess.run(command, capture_output=True, text=True, check=False)
    assert usage.returncode == 2
