import importlib.util
import os

HERE = os.path.dirname(__file__)
PATH = os.path.join(
    HERE, "..", "..", "legion-observability", "scripts", "legion-context-tune.py"
)
SPEC = importlib.util.spec_from_file_location("legion_context_tune", PATH)
lct = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(lct)


def _record(
    fill_pct,
    *,
    schema="legion.handoff.v1",
    model="gpt-5.4",
    context_class="main",
    runner_type="default",
    ts="2026-06-15T00:00:00Z",
    handoff_completed=True,
    continuity_score=0.95,
    resume_success=True,
    native_compaction_seen=False,
    degradation_seen=False,
):
    return {
        "schema": schema,
        "model": model,
        "context_class": context_class,
        "runner_type": runner_type,
        "fill_pct": fill_pct,
        "ts": ts,
        "handoff_completed": handoff_completed,
        "continuity_score": continuity_score,
        "resume_success": resume_success,
        "native_compaction_seen": native_compaction_seen,
        "degradation_seen": degradation_seen,
    }


def test_classify_forced_on_compaction_or_degradation():
    assert lct.classify(_record(0.8, native_compaction_seen=True)) == "forced"
    assert lct.classify(_record(0.8, degradation_seen=True)) == "forced"


def test_classify_clean_on_completed_high_continuity_and_resume():
    assert lct.classify(_record(0.72)) == "clean"


def test_classify_ambiguous_otherwise():
    assert lct.classify(_record(0.72, handoff_completed=False)) == "ambiguous"
    assert lct.classify(_record(0.72, continuity_score=0.5)) == "ambiguous"
    assert lct.classify(_record(0.72, resume_success=False)) == "ambiguous"


def test_estimate_cliff_uses_conservative_p10_and_none_on_empty():
    assert lct.estimate_cliff([]) is None
    assert lct.estimate_cliff([0.88, 0.62, 0.77, 0.71, 0.69, 0.83, 0.74, 0.8, 0.91, 0.66]) == 0.62


def test_propose_t_raises_only_after_clean_streak_and_below_cap():
    records = [
        _record(0.60, ts="2026-06-15T00:00:00Z"),
        _record(0.61, ts="2026-06-15T00:01:00Z"),
        _record(0.62, ts="2026-06-15T00:02:00Z"),
    ]
    proposal = lct.propose_T(records, current_T=0.60, alpha=0.02, k_clean=3)
    assert proposal["proposed_T"] == 0.62
    assert proposal["reason"] == "bounded_exploration"

    not_enough = lct.propose_T(records[:2], current_T=0.60, alpha=0.02, k_clean=3)
    assert not_enough["proposed_T"] == 0.60


def test_propose_t_backs_off_with_recent_forced_and_clamps_to_floor():
    records = [
        _record(0.78, ts="2026-06-15T00:00:00Z"),
        _record(0.79, ts="2026-06-15T00:01:00Z"),
        _record(0.80, ts="2026-06-15T00:02:00Z", native_compaction_seen=True),
    ]
    proposal = lct.propose_T(records, current_T=0.55, floor=0.5, beta=0.5, cooldown=3)
    assert proposal["proposed_T"] == 0.5
    assert proposal["reason"] == "backoff_recent_forced"


def test_propose_t_never_exceeds_cap_t():
    records = [
        _record(0.70, ts="2026-06-15T00:00:00Z", native_compaction_seen=True),
        _record(0.67, ts="2026-06-15T00:00:00Z"),
        _record(0.68, ts="2026-06-15T00:01:00Z"),
        _record(0.69, ts="2026-06-15T00:02:00Z"),
    ]
    proposal = lct.propose_T(
        records,
        current_T=0.64,
        margin=0.05,
        alpha=0.04,
        k_clean=3,
        cooldown=0,
    )
    assert proposal["cap_T"] == 0.65
    assert proposal["proposed_T"] == 0.65


def test_quarantine_excludes_ambiguous_records_from_tuning_counts_and_streaks():
    records = [
        _record(0.60, ts="2026-06-15T00:00:00Z"),
        _record(0.61, ts="2026-06-15T00:01:00Z", handoff_completed=False),
        _record(0.62, ts="2026-06-15T00:02:00Z"),
        _record(0.63, ts="2026-06-15T00:03:00Z"),
    ]
    proposal = lct.propose_T(records, current_T=0.60, alpha=0.02, k_clean=3)
    assert proposal["n_clean"] == 3
    assert proposal["n_ambiguous"] == 1
    assert proposal["proposed_T"] == 0.62


def test_tune_rejects_proposal_that_worsens_weighted_cost():
    records = [
        _record(0.61, ts="2026-06-15T00:00:00Z"),
        _record(0.62, ts="2026-06-15T00:01:00Z"),
        _record(0.63, ts="2026-06-15T00:02:00Z"),
        _record(0.64, ts="2026-06-15T00:03:00Z"),
        _record(0.80, ts="2026-06-15T00:04:00Z", native_compaction_seen=True),
    ]
    key = lct.policy_key(records[0])
    tuned = lct.tune(records, {key: {"T": 0.60}})
    assert tuned[key]["proposed_T"] == 0.50
    assert tuned[key]["decision"] == "rejected_cost"
    assert tuned[key]["T"] == 0.60
    assert tuned[key]["proposed_cost"] > tuned[key]["current_cost"]


def test_tune_respects_min_samples_on_cold_start():
    records = [
        _record(0.61, ts="2026-06-15T00:00:00Z"),
        _record(0.62, ts="2026-06-15T00:01:00Z"),
        _record(0.63, ts="2026-06-15T00:02:00Z"),
        _record(0.64, ts="2026-06-15T00:03:00Z"),
    ]
    key = lct.policy_key(records[0])
    tuned = lct.tune(records, {})
    assert tuned[key]["current_T"] == lct.COLD_START_T
    assert tuned[key]["decision"] == "insufficient_samples"
    assert tuned[key]["T"] == lct.COLD_START_T


def test_weighted_cost_forced_dominates_waste():
    forced = lct.weighted_cost(
        {"forced_rate": 0.1, "cont_fail_rate": 0.0, "token_waste": 0.2}
    )
    waste = lct.weighted_cost(
        {"forced_rate": 0.0, "cont_fail_rate": 0.0, "token_waste": 0.9}
    )
    assert forced > waste
