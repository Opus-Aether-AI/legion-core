import importlib.util
import json
import os
from pathlib import Path


ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
PATH = os.path.join(
    ROOT, "legion-router", "scripts", "normalize-review-verdict.py"
)
SPEC = importlib.util.spec_from_file_location("legion_review_normalizer", PATH)
normalizer = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(normalizer)


def test_generation_schema_uses_supported_subset_without_weakening_validation(tmp_path):
    output = json.loads(Path(ROOT, "legion-router", "schema", "review-verdict-output.schema.json").read_text())

    def check_supported(schema):
        assert not {"allOf", "if", "then", "else", "not"} & set(schema)
        if schema.get("type") == "object":
            assert set(schema["required"]) == set(schema["properties"])
            assert schema["additionalProperties"] is False
            for child in schema["properties"].values():
                check_supported(child)
        if "items" in schema:
            check_supported(schema["items"])

    check_supported(output)
    sample = {"verdict": "request_changes", "summary": "Blocking finding.",
              "findings": [{"severity": "high", "title": "Unsafe path", "detail": "engine.py:12"}]}
    assert normalizer.normalize(json.dumps(sample), tmp_path) == sample
    sample["verdict"] = "approve"
    assert normalizer.normalize(json.dumps(sample), tmp_path) is None
    canonical = json.loads(Path(ROOT, "legion-router", "schema", "review-verdict.schema.json").read_text())
    assert "allOf" in canonical


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


def test_captured_clean_native_review_prose_remains_unrecognized(tmp_path):
    prose = (Path(ROOT) / "tests/fixtures/codex-json/native-review-clean-prose.txt").read_text()

    assert normalizer.normalize(prose, tmp_path) is None


def test_normalizer_rejects_nonblocking_decisions_with_blocking_findings(tmp_path):
    for decision in ("approve", "comment"):
        payload = {
            "verdict": decision,
            "summary": "The decision contradicts the finding.",
            "findings": [
                {"severity": "medium", "title": "A blocking issue remains"}
            ],
        }

        assert normalizer.normalize(json.dumps(payload), tmp_path) is None


def test_normalizer_accepts_only_explicit_no_findings_statements(tmp_path):
    """A clean prose review must still normalize to an approval."""
    for text in (
        "No findings.",
        "no issues",
        "No issues found.",
        "nothing to flag",
        "Review Summary: No findings.",
    ):
        verdict = normalizer.normalize(text, tmp_path)

        assert verdict is not None, text
        assert verdict["verdict"] == "approve"
        assert verdict["findings"] == []


def test_normalizer_never_approves_on_a_conversational_pleasantry(tmp_path):
    """Approval must assert a review outcome, not merely sound positive.

    This gate authorizes publishing a self-authored patch. A reviewer that
    degrades to a stock phrase, or one steered by content inside the diff it is
    reviewing, must not be able to satisfy it.
    """
    for text in (
        "looks good",
        "Looks good!",
        "LGTM",
        "Overall it looks good.",
        "approved",
        "The patch is approved.",
        "",
        "   ",
    ):
        assert normalizer.normalize(text, tmp_path) is None, text
