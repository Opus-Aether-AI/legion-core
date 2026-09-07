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

# (model, input_tokens, output_tokens, expected_usd)
#
# Hand-computed from costs.json, NOT captured from any implementation's output —
# a captured expectation would happily lock in a shared bug.
CASES = [
    # Astra below the long-context threshold: plain 10/50.
    ("gpt-6-astra", 100_000, 10_000, 1.5),
    # Astra above 272K input: input x2, output x1.5.
    ("gpt-6-astra", 300_000, 10_000, 6.75),
    # A v2 row at the same shape must be untouched by the v3 tier logic.
    ("gpt-5.6-terra", 300_000, 10_000, 0.72),
    ("claude-opus-5", 300_000, 10_000, 1.75),
    # Exactly at the threshold is NOT over it.
    ("gpt-6-astra", 272_000, 0, 2.72),
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


@pytest.mark.parametrize("model,inp,out,expected", CASES)
def test_bash_reader_matches_hand_computed(model, inp, out, expected):
    assert _sh_cost(model, inp, out) == pytest.approx(expected, abs=1e-6)


@pytest.mark.parametrize("model,inp,out,expected", CASES)
def test_python_reader_matches_hand_computed(model, inp, out, expected):
    assert _py_cost(model, inp, out) == pytest.approx(expected, abs=1e-6)


@pytest.mark.skipif(shutil.which("bun") is None, reason="bun not installed")
@pytest.mark.parametrize("model,inp,out,expected", CASES)
def test_typescript_reader_matches_hand_computed(model, inp, out, expected, tmp_path):
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


def test_fable_5_1_cache_read_is_cheaper_than_fable_5():
    """5.1 cut cache reads to $0.25/MTok; the generic `fable` row is still $1.

    Ordering carries this: the specific row has to precede the generic one, and
    substring matching means a reordering silently reprices 5.1 four times over.
    """
    assert _sh_cost("claude-fable-5-1", 0, 0, 1_000_000, 0) == pytest.approx(0.25)
    assert _sh_cost("claude-fable-5", 0, 0, 1_000_000, 0) == pytest.approx(1.0)


def test_no_catalogued_model_falls_through_to_the_catch_all():
    """A new model landing on the trailing `gpt-` row under-reports by multiples.

    This is exactly how gpt-6-astra would have been priced at $2.50/$15 instead of
    $10/$50 if its row had not been added ABOVE the catch-all.
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
