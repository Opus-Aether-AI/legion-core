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


def test_unknown_and_partial_costs_are_not_rendered_as_free():
    report = _report()
    report["groups"] = {
        "deepseek": {"count": 1, "ok": 1, "success_rate": 1,
                     "cost_usd": None, "cost_status": "unknown"},
        "mixed": {"count": 2, "ok": 2, "success_rate": 1,
                  "cost_usd": None, "cost_status": "partial", "known_cost_usd": 0.25},
    }
    report["total"].update(
        {"cost_usd": None, "cost_status": "partial", "known_cost_usd": 0.25}
    )

    tui = render.tui(report)
    html = render.to_html(report)
    assert "unknown" in tui
    assert ">=$0.2500" in tui
    assert "unknown" in html
    assert "&gt;=$0.2500" in html


def test_unclassified_partial_cost_renders_as_a_lower_bound():
    report = _report()
    report["classification"].update({
        "unclassified_cost_usd": None,
        "unclassified_cost_status": "partial",
        "unclassified_known_cost_usd": 0.75,
        "unclassified_known_cost_runs": 1,
    })

    tui = render.tui(report)
    rendered_html = render.to_html(report)
    assert "unclassified cost >=$0.7500" in tui
    assert "&gt;=$0.7500" in rendered_html


def test_unclassified_unknown_cost_is_not_rendered_as_free():
    report = _report()
    report["classification"].update({
        "unclassified_cost_usd": None,
        "unclassified_cost_status": "unknown",
        "unclassified_known_cost_usd": None,
        "unclassified_known_cost_runs": 0,
    })

    assert "unclassified cost unknown" in render.tui(report)
    assert "<strong>unknown</strong>" in render.to_html(report)


def test_render_downgrades_unrepresentable_numbers_without_crashing():
    huge = 10**1000
    report = _report()
    report["groups"] = {
        "huge": {
            "count": 1,
            "ok": 1,
            "success_rate": huge,
            "cost_usd": huge,
            "cost_status": "known",
            "p50_ms": huge,
            "p95_ms": huge,
        }
    }
    report["total"].update({"cost_usd": huge, "cost_status": "known"})
    report["classification"].update(
        {"unclassified_cost_usd": huge, "unclassified_cost_status": "known"}
    )

    tui = render.tui(report)
    rendered_html = render.to_html(report)
    assert "unknown" in tui
    assert "unknown" in rendered_html
