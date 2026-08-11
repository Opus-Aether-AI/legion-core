import importlib.util
import os


HERE = os.path.dirname(__file__)
_PATH = os.path.join(
    HERE, "..", "..", "legion-observability", "scripts", "legion-render.py"
)
_spec = importlib.util.spec_from_file_location("legion_render", _PATH)
render = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(render)


def _report():
    return {
        "by": "archetype",
        "groups": {},
        "total": {"count": 2, "ok": 2, "success_rate": 1.0, "cost_usd": 3.0},
        "classification": {
            "delegated_runs": 2,
            "classified_runs": 1,
            "unclassified_runs": 1,
            "classification_rate": 0.5,
            "unclassified_cost_usd": 2.0,
        },
    }


def test_tui_surfaces_classification_coverage_and_cost():
    output = render.tui(_report())

    assert "Routing classification: 1/2 (50.0%)" in output
    assert "unclassified cost $2.0000" in output


def test_html_surfaces_classification_coverage_and_cost():
    output = render.to_html(_report())

    assert "Routing classification" in output
    assert "50.0%" in output
    assert "Unclassified cost" in output
    assert "$2.0000" in output


def test_html_omits_classification_cards_when_no_delegations_exist():
    report = _report()
    report["classification"] = {
        "delegated_runs": 0,
        "classified_runs": 0,
        "unclassified_runs": 0,
        "classification_rate": 0,
        "unclassified_cost_usd": 0,
    }

    output = render.to_html(report)

    assert "Routing classification" not in output
    assert "Unclassified cost" not in output
