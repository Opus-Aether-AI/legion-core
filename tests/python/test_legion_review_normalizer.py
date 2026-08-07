import importlib.util
import json
import os


ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
PATH = os.path.join(
    ROOT, "legion-router", "scripts", "normalize-review-verdict.py"
)
SPEC = importlib.util.spec_from_file_location("legion_review_normalizer", PATH)
normalizer = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(normalizer)


def test_normalizes_builtin_review_findings_and_repo_relative_paths(tmp_path):
    repo = tmp_path / "repo"
    target = repo / "src" / "engine.py"
    target.parent.mkdir(parents=True)
    target.write_text("pass\n", encoding="utf-8")
    prose = (
        "Two issues remain after the remediation.\n\n"
        "Full review comments:\n\n"
        f"- [P1] Preserve the frozen identity — {target}:12-14\n"
        "  The replay path can otherwise publish twice.\n\n"
        f"- [P2] Bound the input — {target}:20\n"
        "  Reject an oversized value before parsing it.\n"
    )

    payload = normalizer.normalize(prose, repo)

    assert payload["verdict"] == "request_changes"
    assert payload["summary"] == "Two issues remain after the remediation."
    assert [item["severity"] for item in payload["findings"]] == ["high", "medium"]
    assert {item["file"] for item in payload["findings"]} == {"src/engine.py"}
    assert payload["findings"][0]["line"] == 12


def test_normalizer_accepts_explicit_no_findings_and_rejects_ambiguous_prose(tmp_path):
    approved = normalizer.normalize(
        "No findings.", tmp_path
    )

    assert approved == {
        "verdict": "approve",
        "summary": "No findings.",
        "findings": [],
    }
    assert normalizer.normalize("Review completed.", tmp_path) is None
    assert normalizer.normalize(
        "I could not establish that there are no issues.", tmp_path
    ) is None
    assert normalizer.normalize(
        "No findings.\n- [P1] unfamiliar finding syntax", tmp_path
    ) is None
    assert normalizer.normalize(
        "Looks good. However, the security boundary is bypassable.", tmp_path
    ) is None
    assert normalizer.normalize(
        "Review summary: no issues. A race remains.", tmp_path
    ) is None


def test_normalizer_preserves_schema_valid_json(tmp_path):
    expected = {
        "verdict": "comment",
        "summary": "One low-priority note.",
        "findings": [{"severity": "low", "title": "Optional cleanup"}],
    }

    assert normalizer.normalize(json.dumps(expected), tmp_path) == expected
