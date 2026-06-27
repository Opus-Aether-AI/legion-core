# SWE-bench Lite adapter (repository-level external benchmark)

[SWE-bench](https://github.com/swe-bench/SWE-bench) is the gold-standard
repository-level coding benchmark: each instance is a real GitHub issue with the
repo pinned at `base_commit`, a hidden `test_patch`, and `FAIL_TO_PASS` /
`PASS_TO_PASS` test ids. A harness "solves" an instance by producing a diff that
makes the failing tests pass without breaking the passing ones.

Unlike `legion-observability/bench/corpora/*.json` (file-overlay tasks graded by a
local command), SWE-bench needs a **repo checkout + a per-repo environment**, so
it is a separate adapter, not a `legion.bench.corpus.v1` corpus.

> **Status:** the fetcher + structural smoke are runnable now (validated on
> `pallets__flask-4045`). The full test-execution eval needs Docker + the official
> `swebench` harness; the Docker daemon was not running in the authoring
> environment, so the end-to-end eval smoke is left as a documented, runnable step
> rather than a recorded result.

## 1. Fetch instances (no install, no Docker)

```bash
python3 fetch_instances.py --out manifest.json --repo pallets/flask --limit 1
# or: --instance pallets__flask-4045   |   --limit 5   |   (all 300)
```

Pulls from the HuggingFace datasets-server API into a `legion.swebench.manifest.v1`
manifest (instance_id, repo, base_commit, problem_statement, patch, test_patch,
FAIL_TO_PASS, PASS_TO_PASS).

## 2. Structural smoke (no Docker)

```bash
bash structural_smoke.sh manifest.json
```

For each instance: fetch the repo at `base_commit` (single-SHA depth-1), apply the
`test_patch`, and confirm the **gold `patch` applies cleanly**. This proves the
instance data + gold oracle are coherent. It does *not* run the tests — that needs
the environment.

## 3. Full eval (needs Docker — the real grade)

The official harness builds a per-instance Docker image, applies a prediction
diff, and runs FAIL_TO_PASS / PASS_TO_PASS:

```bash
pip install swebench
# predictions.jsonl: one {instance_id, model_name_or_path, model_patch} per line.
# The gold patch is the oracle prediction (sanity check the harness):
python -m swebench.harness.run_evaluation \
  --dataset_name princeton-nlp/SWE-bench_Lite \
  --predictions_path gold_predictions.jsonl \
  --max_workers 4 --run_id smoke
```

## 4. Wiring a live Legion mode (design)

To benchmark a harness on SWE-bench, generate `model_patch` predictions, then run
the eval above. Per instance:

1. Fetch repo @ `base_commit` into an isolated workspace and apply `test_patch`.
2. Run the harness on the `problem_statement` (e.g. `legion-delegate run
   --archetype fix-bug --repo <workspace>`, or the direct CLIs).
3. Capture the workspace `git diff` as `model_patch` for that `instance_id`.
4. Feed all predictions to `run_evaluation`; the resolved/unresolved counts are the
   per-mode pass rate, and the `legion.span.v1` spans the adapters emit give the
   real cost — same cost-routing comparison as the corpus tiers, but on real repos.

This stays out of the no-spend CI gate (it needs Docker, network, and real model
spend); it is a manual, budgeted run like the live corpus matrix.
