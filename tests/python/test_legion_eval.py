"""Deterministic gate for legion-eval's scorer internals.

The dataset run is report-only (it's a proxy for model triggering), but the
scorer math + collision detector must be correct and stable — that's what CI
enforces here.
"""
import importlib.util
import os

_HERE = os.path.dirname(os.path.abspath(__file__))
_SCORER = os.path.join(
    _HERE, "..", "..", "legion-observability", "scripts", "legion-eval.py")
_spec = importlib.util.spec_from_file_location("legion_eval", _SCORER)
le = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(le)


# ── tokenize ─────────────────────────────────────────────────────────
def test_tokenize_drops_stopwords_and_short_tokens():
    toks = le.tokenize("Use the Playwright browser to do X")
    assert "playwright" in toks and "browser" in toks
    assert "the" not in toks and "to" not in toks  # stopwords
    assert "x" not in toks                          # 1-char


def test_tokenize_splits_on_punctuation_and_lowercases():
    assert le.tokenize("meta.json, source.config.ts") == {
        "meta", "json", "source", "config", "ts"}


# ── score ────────────────────────────────────────────────────────────
def test_score_zero_without_overlap():
    assert le.score({"alpha"}, {"beta"}) == 0.0
    assert le.score(set(), {"beta"}) == 0.0


def test_score_overlap_dominates_jaccard_tiebreak():
    # Two desc sets, same single overlap word, but the tighter set scores higher.
    prompt = {"playwright", "screenshot"}
    tight = le.score(prompt, {"playwright", "screenshot"})       # full overlap
    loose = le.score(prompt, {"playwright", "screenshot", "x", "y", "z"})
    assert tight > loose
    # Raw intersection drives magnitude: 2 overlaps beat 1 overlap regardless.
    assert le.score(prompt, {"playwright", "screenshot"}) > le.score(
        prompt, {"playwright", "unrelated", "words", "here"})


# ── rank ─────────────────────────────────────────────────────────────
def _plugins(*pairs):
    return [{"name": n, "tokens": le.tokenize(d)} for n, d in pairs]


def test_rank_orders_by_score_then_name():
    plugins = _plugins(
        ("router", "delegate task to gpt codex metered diff"),
        ("docs", "edit fumadocs mdx page"),
    )
    ranked = le.rank("delegate a gpt codex task", plugins)
    assert ranked[0][0] == "router"
    assert ranked[0][1] > ranked[1][1]


# ── evaluate_case ────────────────────────────────────────────────────
def test_evaluate_case_pass():
    plugins = _plugins(
        ("router", "delegate task to gpt codex metered diff worktree"),
        ("docs", "edit fumadocs mdx page meta navigation"),
    )
    r = le.evaluate_case(
        {"prompt": "delegate a gpt codex task for a metered diff", "expect": "router"},
        plugins, top_k=3, gap=0.5)
    assert r["status"] == "pass" and r["in_top1"]


def test_evaluate_case_collision_when_expected_loses_by_a_hair():
    # Same 3 overlapping tokens; expected just has one extra word, so its Jaccard
    # (and thus score) is a hair lower -> it places #2 within the gap = collision.
    plugins = _plugins(
        ("aaa-cli", "automate browser playwright"),
        ("bbb-patterns", "automate browser playwright extra"),
    )
    r = le.evaluate_case(
        {"prompt": "automate browser playwright", "expect": "bbb-patterns"},
        plugins, top_k=3, gap=0.5)
    # aaa-cli wins by name tiebreak at a near-equal score -> collision, not silent miss
    assert r["status"] == "collision", r
    assert r["in_topk"] and not r["in_top1"]


def test_evaluate_case_miss_when_expected_far_behind():
    plugins = _plugins(
        ("router", "delegate gpt codex metered diff"),
        ("docs", "fumadocs mdx page"),
    )
    r = le.evaluate_case(
        {"prompt": "delegate gpt codex diff", "expect": "docs"},
        plugins, top_k=3, gap=0.5)
    assert r["status"] == "miss"


def test_evaluate_case_false_trigger_is_a_miss():
    plugins = _plugins(
        ("router", "delegate gpt codex metered diff"),
        ("docs", "fumadocs mdx page meta"),
    )
    r = le.evaluate_case(
        {"prompt": "delegate gpt codex diff", "expect": "router",
         "expect_not": "router"},
        plugins, top_k=3, gap=0.5)
    assert r["false_trigger"] and r["status"] != "pass"


def test_evaluate_case_can_target_non_plugin_entities():
    targets = [
        {
            "type": "command",
            "name": "feature",
            "tokens": le.tokenize("feature lane planning implementation validation pr"),
        },
        {
            "type": "skill",
            "name": "workflow-orchestrator",
            "tokens": le.tokenize("delivery workflow orchestrator"),
        },
    ]
    r = le.evaluate_case(
        {
            "prompt": "run the feature lane validation and PR workflow",
            "expect_type": "command",
            "expect": "feature",
        },
        targets,
        top_k=3,
        gap=0.5,
    )
    assert r["status"] == "pass"
    assert r["got_type"] == "command"


# ── summarize ────────────────────────────────────────────────────────
def test_summarize_counts_and_rates():
    results = [
        {"status": "pass", "in_top1": True, "in_topk": True},
        {"status": "collision", "in_top1": False, "in_topk": True},
        {"status": "miss", "in_top1": False, "in_topk": False},
    ]
    s = le.summarize(results)
    assert s["cases"] == 3 and s["pass"] == 1 and s["collision"] == 1 and s["miss"] == 1
    assert s["precision_at_1"] == round(1 / 3, 3)
    assert s["hit_at_k"] == round(2 / 3, 3)


def test_simple_yaml_fallback_parser_loads_shipped_shape():
    text = """
cases:
  - prompt: "Delegate this task"
    expect: legion-router
    why: router-specific
  - prompt: "Edit docs"
    expect: fumadocs-authoring
    expect_not: legion-router
    why: docs should not route to delegation
"""
    cases = le._load_simple_cases_yaml(text)
    assert cases == [
        {"prompt": "Delegate this task", "expect": "legion-router", "why": "router-specific"},
        {
            "prompt": "Edit docs",
            "expect": "fumadocs-authoring",
            "expect_not": "legion-router",
            "why": "docs should not route to delegation",
        },
    ]


def test_simple_yaml_fallback_parser_loads_entity_shape():
    text = """
cases:
  - prompt: "Run feature lane"
    expect_type: command
    expect: feature
    expect_not_type: skill
    expect_not: workflow-orchestrator
    why: command-specific
"""
    cases = le._load_simple_cases_yaml(text)
    assert cases == [
        {
            "prompt": "Run feature lane",
            "expect_type": "command",
            "expect": "feature",
            "expect_not_type": "skill",
            "expect_not": "workflow-orchestrator",
            "why": "command-specific",
        }
    ]


def test_auto_scope_loads_all_targets_for_mixed_plugin_entity_cases():
    cases = [
        {"prompt": "Delegate this task", "expect": "legion-router"},
        {"prompt": "Run feature lane", "expect_type": "command", "expect": "feature"},
    ]

    assert le._scope_for_cases(cases, "auto") == "all"


# ── the shipped dataset stays healthy (report-only, but guard the floor) ──
def test_shipped_dataset_has_high_precision():
    repo = os.path.abspath(os.path.join(_HERE, "..", ".."))
    plugins = le.load_plugins(repo)
    ds = os.path.join(repo, "legion-observability", "eval", "skill-triggering.yaml")
    cases = le._load_dataset(ds)
    results = [le.evaluate_case(c, plugins, 3, 0.5) for c in cases]
    summary = le.summarize(results)
    # The curated set should route cleanly under the proxy; a regression here
    # means a description change made a skill ambiguous.
    assert summary["precision_at_1"] >= 0.9, summary


def test_entity_dataset_has_high_precision():
    repo = os.path.abspath(os.path.join(_HERE, "..", ".."))
    targets = le.load_targets(repo, "entity")
    ds = os.path.join(repo, "legion-observability", "eval", "entity-triggering.yaml")
    cases = le._load_dataset(ds)
    results = [le.evaluate_case(c, targets, 3, 0.5) for c in cases]
    summary = le.summarize(results)
    assert summary["precision_at_1"] >= 0.9, summary
