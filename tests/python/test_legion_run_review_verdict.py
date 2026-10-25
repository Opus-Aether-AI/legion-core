"""The review gate must read a verdict a reviewer would plausibly write.

Regression: on 2026-08-21 a retired Claude review returned ``verdict: "approve"`` with a full findings
list, exit code 0, and legion-run recorded the stage as failed with "invalid terminal verdict:
expected a structured verdict object". The verdict was valid. It was wrapped in a ```json fence,
which ``_review_verdict_value`` did not unwrap, so the string never became an object and schema
validation rejected it. The failure then skipped evaluate, report and share.
"""

import importlib.util
import json
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
LEGION_RUN_PATH = ROOT / "legion-orchestrate" / "scripts" / "legion-run.py"


def load_legion_run():
    spec = importlib.util.spec_from_file_location("legion_run_review_verdict", LEGION_RUN_PATH)
    assert spec is not None
    module = importlib.util.module_from_spec(spec)
    assert spec.loader is not None
    spec.loader.exec_module(module)
    return module


legion_run = load_legion_run()

APPROVE = {
    "verdict": "approve",
    "summary": "Data-only diff. Re-verified every gate the deterministic validator checks.",
    "findings": [],
}


def _fenced(payload: dict, language: str = "json") -> str:
    return f"```{language}\n{json.dumps(payload, indent=2)}\n```"


def test_unwraps_a_json_fenced_verdict():
    """The exact shape that broke the arena ideation run."""
    value = legion_run._review_verdict_value({"result": _fenced(APPROVE)})
    assert value == APPROVE
    assert legion_run._review_verdict_schema_error(value) == ""


def test_unwraps_a_fence_with_no_language_tag():
    value = legion_run._review_verdict_value({"result": _fenced(APPROVE, language="")})
    assert value == APPROVE


def test_unwraps_a_fence_padded_with_whitespace():
    value = legion_run._review_verdict_value({"result": f"\n\n  {_fenced(APPROVE)}  \n"})
    assert value == APPROVE


def test_still_reads_a_bare_json_object():
    """The path that already worked must keep working."""
    value = legion_run._review_verdict_value({"result": json.dumps(APPROVE)})
    assert value == APPROVE


def test_passes_through_an_object_that_is_already_parsed():
    value = legion_run._review_verdict_value({"verdict": APPROVE})
    assert value == APPROVE


def test_carries_findings_through_the_fence():
    """A blocking finding inside a fenced verdict must still block."""
    payload = {
        "verdict": "request_changes",
        "summary": "One correctness defect.",
        "findings": [
            {
                "severity": "high",
                "title": "Off-by-one in the replay bound",
                "file": "src/replay.py",
                "line": 42,
                "detail": "The last event is dropped.",
            }
        ],
    }
    value = legion_run._review_verdict_value({"result": _fenced(payload)})
    assert value == payload
    assert legion_run._review_verdict_schema_error(value) == ""
    assert len(legion_run._blocking_review_findings(value)) == 1


def test_leaves_prose_alone():
    """Prose is not a verdict, and pretending otherwise would hide a broken reviewer."""
    prose = "Looks fine to me, ship it."
    assert legion_run._review_verdict_value({"result": prose}) == prose
    assert legion_run._review_verdict_schema_error(prose) != ""


def test_leaves_an_unterminated_fence_alone():
    """A gate that gets creative about malformed input is worse than one that rejects it."""
    broken = '```json\n{"verdict": "approve"'
    assert legion_run._review_verdict_value({"result": broken}) == broken


def test_leaves_invalid_json_inside_a_fence_alone():
    broken = '```json\n{"verdict": "approve",}\n```'
    assert legion_run._review_verdict_value({"result": broken}) == broken


def test_rejects_a_fenced_json_array():
    """Unwrapping must not turn a non-object into an accepted verdict."""
    fenced_list = "```json\n[1, 2, 3]\n```"
    value = legion_run._review_verdict_value({"result": fenced_list})
    assert value == fenced_list
    assert legion_run._review_verdict_schema_error(value) != ""


def test_strip_code_fence_is_a_noop_for_plain_text():
    assert legion_run._strip_code_fence("  hello  ") == "hello"


# ── 25 Oct 2026: prose, then the verdict in a fence ────────────────────────
# A Claude reviewer explained its check in a paragraph and then gave a valid
# approval in a ```json block. The gate only unwrapped a fence that was the
# whole answer, so it reported "expected a structured verdict object".
PROSE_THEN_FENCE = (
    "I checked the range: the diff is empty, so here is the verdict.\n\n"
    + _fenced(
        {
            "verdict": "approve",
            "summary": "The range is empty.",
            "findings": [
                {"severity": "low", "title": "The diff under review is empty", "detail": "Check the run."}
            ],
        }
    )
)


def test_reads_the_one_fenced_verdict_that_follows_prose():
    value = legion_run._review_verdict_value({"result": PROSE_THEN_FENCE})
    assert isinstance(value, dict) and value["verdict"] == "approve"
    assert legion_run._review_failure_reason({"status": "ok", "result": PROSE_THEN_FENCE}) == ""


def test_a_blocking_finding_in_a_fenced_verdict_after_prose_still_blocks():
    payload = {
        "verdict": "approve",
        "summary": "Fine apart from one thing.",
        "findings": [{"severity": "high", "title": "Drops the last event"}],
    }
    text = "Here is my review.\n\n" + _fenced(payload)
    assert "blocking finding" in legion_run._review_failure_reason({"status": "ok", "result": text})


def test_two_fenced_verdicts_are_not_a_verdict():
    """Picking one of two would let a quoted example stand in for the answer."""
    text = (
        "The diff adds this example:\n\n" + _fenced(APPROVE)
        + "\n\nMy verdict:\n\n" + _fenced(dict(APPROVE, verdict="request_changes"))
    )
    assert legion_run._review_verdict_value({"result": text}) == text


def test_prose_priority_findings_are_not_overruled_by_a_fenced_approval():
    text = "- [P1] Missing authorization check — auth.py:42\n\n" + _fenced(APPROVE)
    assert legion_run._review_verdict_value({"result": text}) == text


def test_extra_finding_fields_fold_into_detail():
    """The fold the router's normaliser makes, so legion-run's gate accepts the same verdicts."""
    payload = {
        "verdict": "approve",
        "summary": "One note.",
        "findings": [
            {"severity": "low", "title": "Naming", "detail": "Rename it.", "failure_scenario": "none"}
        ],
    }
    value = legion_run._review_verdict_value({"result": _fenced(payload)})
    assert legion_run._review_verdict_schema_error(value) == ""
    assert value["findings"][0]["detail"] == "Rename it.\nfailure_scenario: none"
    assert value["verdict"] == "approve" and value["findings"][0]["severity"] == "low"
    # an extra field at the top level is still a schema error
    top = dict(payload, confidence="high")
    assert legion_run._review_verdict_schema_error(
        legion_run._review_verdict_value({"result": json.dumps(top)})
    ) != ""
