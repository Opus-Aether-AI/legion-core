#!/usr/bin/env python3
"""Import Aider Polyglot exercises into legion.bench.corpus.v1.

Source repository: https://github.com/Aider-AI/polyglot-benchmark
License note: exercises are Exercism content and the Polyglot benchmark repo is
distributed under MIT.

Regenerate the corpus by re-running this script against a checkout of
Aider-AI/polyglot-benchmark.
"""

from __future__ import annotations

import argparse
import json
import os
import subprocess
import sys
import tempfile
from pathlib import Path
from typing import Any


SOURCE_REPO_URL = "https://github.com/Aider-AI/polyglot-benchmark"


def _eprint(message: str) -> None:
    print(message, file=sys.stderr)


def _read_json(path: Path) -> dict[str, Any]:
    with path.open(encoding="utf-8") as handle:
        data = json.load(handle)
    if not isinstance(data, dict):
        raise ValueError(f"expected JSON object in {path}")
    return data


def _read_text(path: Path) -> str:
    with path.open(encoding="utf-8") as handle:
        return handle.read()


def _safe_target(root: Path, rel: str) -> Path:
    if os.path.isabs(rel):
        raise ValueError(f"absolute paths are not allowed: {rel}")
    target = (root / rel).resolve()
    try:
        target.relative_to(root.resolve())
    except ValueError as exc:
        raise ValueError(f"path escapes workspace: {rel}") from exc
    return target


def _write_files(root: Path, files: dict[str, str]) -> None:
    for rel, content in files.items():
        path = _safe_target(root, rel)
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(content, encoding="utf-8")


def _render_string(template: str, context: dict[str, str]) -> str:
    rendered = template
    for key, value in context.items():
        rendered = rendered.replace("{" + key + "}", value)
    return rendered


def _copy_modes() -> list[dict[str, Any]]:
    corpus_path = Path(__file__).resolve().parents[1] / "corpora" / "heldout-oss-36.json"
    payload = _read_json(corpus_path)
    modes = payload.get("modes")
    if not isinstance(modes, list):
        raise ValueError(f"missing modes array in {corpus_path}")
    return modes


def _case_prefix(lang: str) -> str:
    if lang == "python":
        return "poly-py"
    return f"poly-{lang}"


def _best_effort_answer_files(
    exercise_dir: Path,
    solution_files: list[str],
    example_files: list[str],
) -> dict[str, str]:
    if not solution_files:
        return {}
    if not example_files:
        raise ValueError("files.example is empty")

    example_text = {example: _read_text(exercise_dir / example) for example in example_files}
    if len(solution_files) == len(example_files):
        return {
            solution: example_text[example]
            for solution, example in zip(solution_files, example_files)
        }

    remaining = list(example_files)
    answer_files: dict[str, str] = {}
    for index, solution in enumerate(solution_files):
        match = None
        solution_name = Path(solution).name
        solution_stem = Path(solution).stem
        for candidate in remaining:
            candidate_path = Path(candidate)
            if candidate_path.name == solution_name or candidate_path.stem == solution_stem:
                match = candidate
                break
        if match is None:
            match = remaining[min(index, len(remaining) - 1)]
        answer_files[solution] = example_text[match]
        if match in remaining and len(remaining) > 1:
            remaining.remove(match)
    return answer_files


def _build_case(exercise_dir: Path, lang: str) -> dict[str, Any]:
    config_path = exercise_dir / ".meta" / "config.json"
    config = _read_json(config_path)
    files = config.get("files")
    if not isinstance(files, dict):
        raise ValueError(f"missing files object in {config_path}")

    solution_files = [str(item) for item in files.get("solution") or []]
    test_files = [str(item) for item in files.get("test") or []]
    example_files = [str(item) for item in files.get("example") or []]
    if not solution_files:
        raise ValueError("files.solution is empty")
    if not test_files:
        raise ValueError("files.test is empty")

    case_files: dict[str, str] = {}
    for rel in [*solution_files, *test_files]:
        case_files[rel] = _read_text(exercise_dir / rel)

    summary = str(config.get("blurb") or exercise_dir.name).strip() or exercise_dir.name
    case_id = f"{_case_prefix(lang)}-{exercise_dir.name}"
    solution_list = ", ".join(solution_files)
    validators = [{
        "type": "command",
        "command": ["python3", "-m", "pytest", "-q", *test_files],
        "cwd": "{workspace}",
        "timeout": 30,
    }]
    return {
        "id": case_id,
        "dimension": f"polyglot-{lang}",
        "summary": summary,
        "task": f"Edit {solution_list} only so the tests pass. {summary}",
        "files": case_files,
        "answer_files": _best_effort_answer_files(exercise_dir, solution_files, example_files),
        "validators": validators,
        "required": True,
    }


def _short(text: str, limit: int = 160) -> str:
    collapsed = " ".join(text.split())
    if len(collapsed) <= limit:
        return collapsed
    return collapsed[: limit - 3].rstrip() + "..."


def _run_case_files(files: dict[str, str], validators: list[dict[str, Any]]) -> tuple[bool, str]:
    env = os.environ.copy()
    env["PYTHONDONTWRITEBYTECODE"] = "1"
    with tempfile.TemporaryDirectory(prefix="aider-polyglot-") as tmp:
        workspace = Path(tmp)
        _write_files(workspace, files)
        context = {"workspace": str(workspace)}
        for validator in validators:
            if validator.get("type") != "command":
                return False, f"unsupported validator type: {validator.get('type')!r}"
            command = [str(item) for item in validator.get("command") or []]
            if not command:
                return False, "empty validator command"
            cwd = _render_string(str(validator.get("cwd") or "{workspace}"), context)
            timeout = int(validator.get("timeout") or 30)
            expected_exit = int(validator.get("expect_exit") or 0)
            try:
                proc = subprocess.run(
                    command,
                    cwd=cwd,
                    env=env,
                    text=True,
                    stdout=subprocess.PIPE,
                    stderr=subprocess.PIPE,
                    timeout=timeout,
                )
            except subprocess.TimeoutExpired as exc:
                return False, f"timeout after {timeout}s: {_short(exc.stderr or exc.stdout or '')}"
            ok = proc.returncode == expected_exit
            detail = (
                f"exit={proc.returncode} expected={expected_exit}; "
                f"stdout={_short(proc.stdout)}; stderr={_short(proc.stderr)}"
            )
            if not ok:
                return False, detail
        return True, "ok"


def _self_filter(case: dict[str, Any]) -> tuple[bool, str]:
    oracle_files = dict(case["files"])
    oracle_files.update(case["answer_files"])
    oracle_ok, oracle_detail = _run_case_files(oracle_files, list(case["validators"]))
    if not oracle_ok:
        return False, f"oracle failed: {oracle_detail}"

    baseline_ok, baseline_detail = _run_case_files(dict(case["files"]), list(case["validators"]))
    if baseline_ok:
        return False, f"baseline unexpectedly passed: {baseline_detail}"
    return True, "included"


def _language_title(lang: str) -> str:
    if not lang:
        return lang
    return lang.replace("-", " ").title()


def _source_commit(src: Path) -> str:
    """Best-effort pinned commit of the polyglot checkout (embedded for provenance)."""
    try:
        proc = subprocess.run(
            ["git", "-C", str(src), "rev-parse", "HEAD"],
            stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True, timeout=10,
        )
        return proc.stdout.strip() if proc.returncode == 0 else ""
    except Exception:
        return ""


def _build_corpus(lang: str, cases: list[dict[str, Any]], source_commit: str) -> dict[str, Any]:
    reliable_floor = min(30, len(cases))
    return {
        "schema": "legion.bench.corpus.v1",
        "corpus": f"aider-polyglot-{lang}",
        "description": (
            f"Aider Polyglot (Exercism) {_language_title(lang)} practice exercises, "
            "imported as a held-out external corpus. Generated by "
            "bench/tools/import-aider-polyglot.py from Aider-AI/polyglot-benchmark."
        ),
        "source": {
            "repo": SOURCE_REPO_URL,
            "commit": source_commit,
            "license": "MIT (see bench/corpora/THIRD_PARTY_LICENSES.md)",
            "generator": "bench/tools/import-aider-polyglot.py",
        },
        "baseline": "scripted-baseline",
        "reliability_min_cases": reliable_floor,
        "required_clean_modes": ["scripted-oracle"],
        "modes": _copy_modes(),
        "cases": sorted(cases, key=lambda case: str(case.get("id") or "")),
    }


def _exercise_dirs(src: Path, lang: str) -> list[Path]:
    root = src / lang / "exercises" / "practice"
    if not root.is_dir():
        raise FileNotFoundError(f"practice exercise directory not found: {root}")
    return sorted(path for path in root.iterdir() if path.is_dir())


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--src", required=True, help="Checkout of Aider-AI/polyglot-benchmark")
    parser.add_argument("--lang", required=True, help="Language subdirectory to import, e.g. python")
    parser.add_argument("--out", required=True, help="Output corpus JSON path")
    parser.add_argument("--limit", type=int, default=None, help="Process only the first N exercises")
    args = parser.parse_args()

    src = Path(args.src).expanduser().resolve()
    out_path = Path(args.out).expanduser().resolve()
    exercises = _exercise_dirs(src, args.lang)
    if args.limit is not None:
        exercises = exercises[: max(args.limit, 0)]

    included: list[dict[str, Any]] = []
    skipped: list[tuple[str, str]] = []
    for exercise_dir in exercises:
        case_id = f"{_case_prefix(args.lang)}-{exercise_dir.name}"
        try:
            case = _build_case(exercise_dir, args.lang)
            ok, reason = _self_filter(case)
            if ok:
                included.append(case)
            else:
                skipped.append((case_id, reason))
        except Exception as exc:  # pragma: no cover - importer should report and keep going.
            skipped.append((case_id, str(exc)))

    if not included:
        _eprint("Included (0):")
        _eprint("Skipped:")
        for case_id, reason in skipped:
            _eprint(f"  {case_id}: {reason}")
        _eprint("No exercises survived the self-filter.")
        return 1

    corpus = _build_corpus(args.lang, included, _source_commit(src))
    out_path.parent.mkdir(parents=True, exist_ok=True)
    with out_path.open("w", encoding="utf-8") as handle:
        json.dump(corpus, handle, indent=2, ensure_ascii=False)
        handle.write("\n")

    _eprint(
        f"Imported {len(included)} of {len(exercises)} {args.lang} practice exercises "
        f"from {SOURCE_REPO_URL}."
    )
    _eprint("Included:")
    for case in corpus["cases"]:
        _eprint(f"  {case['id']}")
    _eprint(f"Skipped ({len(skipped)}):")
    for case_id, reason in skipped:
        _eprint(f"  {case_id}: {reason}")
    if len(included) < 30:
        _eprint(
            "Reliability floor lowered to included case count because fewer than 30 "
            "exercises survived the self-filter."
        )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
