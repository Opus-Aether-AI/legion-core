"""The cost table has THREE independent readers; this pins them to one answer.

`legion-router/config/costs.json` is consumed by three separate implementations of
the same formula:

  * `legion-router/scripts/lib/cost.sh`            (bash + jq)
  * `legion-router/scripts/router.ts`              (TypeScript, `costForModel`)
  * `legion-observability/scripts/legion-activity.py` (Python, `cost_for`)

Nothing structural stops them drifting, and a drift is close to invisible: every
reader keeps returning a plausible dollar figure, they just stop agreeing, and the
cost-aware routing that reads them starts making decisions on numbers that depend
on which code path happened to compute them. Schema v3's `long_context` tier made
that risk concrete — it had to be added to all three by hand.

These tests are the tripwire. When they fail, the fix is to make the readers agree
again, not to update one expectation.
"""

import importlib.util
import json
import os
import shutil
import subprocess

import pytest

HERE = os.path.dirname(__file__)
ROOT = os.path.abspath(os.path.join(HERE, "..", ".."))
COSTS = os.path.join(ROOT, "legion-router", "config", "costs.json")
COST_SH = os.path.join(ROOT, "legion-router", "scripts", "lib", "cost.sh")
ROUTER_TS = os.path.join(ROOT, "legion-router", "scripts", "router.ts")

_ACTIVITY = os.path.join(ROOT, "legion-observability", "scripts", "legion-activity.py")
_spec = importlib.util.spec_from_file_location("legion_activity", _ACTIVITY)
activity = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(activity)

MODELS_TOML = os.path.join(ROOT, "legion-router", "config", "models.toml")

_ROUTE = os.path.join(ROOT, "legion-router", "scripts", "legion-route.py")
_route_spec = importlib.util.spec_from_file_location("legion_route", _ROUTE)
route = importlib.util.module_from_spec(_route_spec)
_route_spec.loader.exec_module(route)

CATALOG = route.load_models(MODELS_TOML)


def _model(role):
    """Resolve a role to its id.

    Cases name ROLES, never ids: test_model_config_centralized asserts that only
    models.toml and costs.json contain concrete model ids, and this file is
    tracked, so a literal id here fails that gate. Resolving also means repointing
    a role surfaces here as a price mismatch — which is the right failure, since a
    new model behind an old role is exactly when these figures need rechecking.
    """
    return CATALOG[role]


# (role, input_tokens, output_tokens, expected_usd)
#
# Hand-computed from costs.json, NOT captured from any implementation's output —
# a captured expectation would happily lock in a shared bug.
CASES = [
    # The frontier codex role below the long-context threshold: plain 10/50.
    ("codex_frontier", 100_000, 10_000, 1.5),
    # Above 272K input: input x2, output x1.5.
    ("codex_frontier", 300_000, 10_000, 6.75),
    # v2 rows at the same shape must be untouched by the v3 tier logic.
    ("codex_workhorse", 300_000, 10_000, 0.72),
    ("claude_default", 300_000, 10_000, 1.75),
    # Exactly at the threshold is NOT over it.
    ("codex_frontier", 272_000, 0, 2.72),
]

# (role, input_tokens, output_tokens, cached_tokens, expected_usd)
#
# The cache path was uncovered by CASES, which always passes 0 cached tokens —
# so the readers could disagree on whether cached tokens count toward the
# long-context threshold and nothing would say so. Python's `cost_for` takes
# input_tokens INCLUSIVE of cached, and bills the difference; jq and TypeScript
# take them separately. These cases pin both spellings to the same dollars.
CACHED_CASES = [
    # 100K prompt of which 60K is cached, below threshold:
    #   40K uncached @ $10 + 60K cached @ $1 + 10K out @ $50 = 0.4 + 0.06 + 0.5
    ("codex_frontier", 100_000, 10_000, 60_000, 0.96),
    # 300K prompt of which 100K is cached, ABOVE threshold (prompt counts cached):
    #   200K @ $10 x2 + 100K @ $1 x2 + 10K out @ $50 x1.5 = 4.0 + 0.2 + 0.75
    ("codex_frontier", 300_000, 10_000, 100_000, 4.95),
]


def _sh_cost(model, inp, out, cache_read=0, cache_write=0):
    res = subprocess.run(
        ["bash", COST_SH, model, str(inp), str(out), str(cache_read), str(cache_write)],
        capture_output=True, text=True, check=True,
    )
    return float(res.stdout.strip())


def _py_cost(model, inp, out, cached=0):
    costs = activity.load_costs(COSTS)
    usage = {"input_tokens": inp, "output_tokens": out, "cached_input_tokens": cached}
    return activity.cost_for(model, usage, costs)


@pytest.mark.parametrize("role,inp,out,expected", CASES)
def test_bash_reader_matches_hand_computed(role, inp, out, expected):
    assert _sh_cost(_model(role), inp, out) == pytest.approx(expected, abs=1e-6)


@pytest.mark.parametrize("role,inp,out,expected", CASES)
def test_python_reader_matches_hand_computed(role, inp, out, expected):
    assert _py_cost(_model(role), inp, out) == pytest.approx(expected, abs=1e-6)


@pytest.mark.skipif(shutil.which("bun") is None, reason="bun not installed")
@pytest.mark.parametrize("role,inp,out,expected", CASES)
def test_typescript_reader_matches_hand_computed(role, inp, out, expected, tmp_path):
    model = _model(role)
    # router.ts binds its port at import time and Bun.serve keeps the process
    # alive, so the probe must (a) take a port of its own, well away from the
    # daemon's 8082, and (b) exit explicitly. Without the exit every probe lingers
    # holding its port, and the next one dies on EADDRINUSE.
    port = 19000 + (abs(hash((model, inp, out))) % 900)
    probe = tmp_path / "probe.ts"
    probe.write_text(
        f'import {{ costForModel }} from "{ROUTER_TS}";\n'
        f'console.log("COST=" + costForModel("{model}", {inp}, {out}, 0, 0));\n'
        f"process.exit(0);\n"
    )
    env = {**os.environ, "ROUTER_PORT": str(port)}
    res = subprocess.run(
        ["bun", "run", str(probe)], capture_output=True, text=True, env=env,
        timeout=60, check=False,
    )
    assert res.returncode == 0, f"probe failed: {res.stderr[-800:]}"
    line = next(ln for ln in res.stdout.splitlines() if ln.startswith("COST="))
    assert float(line.split("=", 1)[1]) == pytest.approx(expected, abs=1e-6)


@pytest.mark.parametrize("role,inp,out,cached,expected", CACHED_CASES)
def test_bash_reader_prices_cached_tokens(role, inp, out, cached, expected):
    # cost.sh takes UNCACHED input and cache_read separately.
    got = _sh_cost(_model(role), inp - cached, out, cached, 0)
    assert got == pytest.approx(expected, abs=1e-6)


@pytest.mark.parametrize("role,inp,out,cached,expected", CACHED_CASES)
def test_python_reader_prices_cached_tokens(role, inp, out, cached, expected):
    # cost_for takes input_tokens INCLUSIVE of cached and subtracts internally,
    # so the same request is spelled differently here. Same dollars or the two
    # readers disagree about what "prompt size" means.
    got = _py_cost(_model(role), inp, out, cached)
    assert got == pytest.approx(expected, abs=1e-6)


def test_frontier_claude_cache_read_beats_its_prior_generation():
    """The current frontier id must hit its OWN row, not the generic family row.

    Matching is by substring with first-match-wins, so the specific row has to
    precede the generic one. Reorder them and the frontier model silently reprices
    to the family rate — a 4x error on cache reads that nothing else would catch.
    The prior-generation id is derived from the current one rather than written
    out, because concrete ids belong only in the catalogs.
    """
    frontier = _model("claude_frontier")
    prior_generation = frontier.rsplit("-", 1)[0]
    assert prior_generation != frontier, "expected a point-release id to derive from"
    specific = _sh_cost(frontier, 0, 0, 1_000_000, 0)
    generic = _sh_cost(prior_generation, 0, 0, 1_000_000, 0)
    assert specific < generic, (
        f"{frontier} cache reads ({specific}) should be cheaper than "
        f"{prior_generation} ({generic}); check the row ORDER in costs.json"
    )


def test_no_catalogued_model_falls_through_to_the_catch_all():
    """A new model landing on the trailing catch-all row under-reports by multiples.

    The frontier codex model would have been priced at a quarter of its real input
    rate, and under a third of its output rate, had its row not been added ABOVE
    the generic family entry. Nothing would have surfaced that: every reader keeps
    returning a plausible number.
    """
    with open(COSTS, encoding="utf-8") as handle:
        table = json.load(handle)
    rows = table["models"]
    catch_all = rows[-1]["match"]

    models_toml = os.path.join(ROOT, "legion-router", "config", "models.toml")
    with open(models_toml, encoding="utf-8") as handle:
        body = handle.read()

    catalogued = set()
    for line in body.splitlines():
        line = line.split("#", 1)[0].strip()
        if "=" in line and '"' in line:
            catalogued.add(line.split('"')[1])

    offenders = []
    for model in sorted(catalogued):
        lowered = model.lower()
        hit = next((r["match"] for r in rows if r["match"] in lowered), None)
        if hit is None or hit == catch_all:
            offenders.append(model)
    assert not offenders, (
        f"models priced by the catch-all row or not at all: {offenders}. "
        "Add a specific row ABOVE the trailing generic entry in costs.json."
    )
