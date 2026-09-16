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
