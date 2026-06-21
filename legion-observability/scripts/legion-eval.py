#!/usr/bin/env python3
"""legion-eval — does each plugin/skill trigger for the right prompts?

Claude Code routes a user prompt to a skill by matching the prompt against each
plugin's SKILL.md `description`. We can't run the real model in CI, so this is a
deterministic LEXICAL PROXY: it scores prompt<->description token overlap, ranks
the plugins, and checks whether the expected plugin wins (or at least places).

That proxy is NOT the model — but it is a useful, repeatable signal: it catches
gross mis-triggers, and it surfaces COLLISIONS (two plugins whose descriptions
are near-ties for the same prompt, e.g. the 4-way Playwright cluster), which is
exactly where real triggering gets unreliable.

Usage:
  legion-eval [--repo DIR] [--dataset FILE] [--json] [--top-k N] [--gap G]
  legion-eval --explain "<prompt>"        # show the ranked plugins for one prompt

Always exits 0 in report mode (it's a signal, not a gate). The deterministic
scorer internals are gated by tests/python/test_legion_eval.py.
"""
from __future__ import annotations

import argparse
import importlib.util
import json
import os
import re
import sys
from typing import Any

# Minimal stopword set — words too generic to carry trigger signal.
STOPWORDS = {
    "the", "a", "an", "and", "or", "of", "to", "for", "in", "on", "with", "is",
    "are", "be", "this", "that", "it", "as", "at", "by", "from", "into", "via",
    "use", "used", "using", "when", "how", "do", "i", "my", "you", "your", "we",
    "can", "should", "need", "want", "please", "help", "me", "across", "so",
    "also", "etc", "e", "g", "ie", "covers", "includes", "plus", "per", "any",
}


def tokenize(text: str) -> set[str]:
    """Lowercase, split on non-alphanumerics, drop stopwords + 1-char tokens."""
    toks = re.split(r"[^a-z0-9]+", (text or "").lower())
    return {t for t in toks if len(t) > 1 and t not in STOPWORDS}


def score(prompt_tokens: set[str], desc_tokens: set[str]) -> float:
    """Overlap-driven score with a small Jaccard tie-breaker.

    Raw intersection size dominates (matching more distinctive words matters most);
    Jaccard (intersection / union) breaks ties toward the tighter-fitting
    description so a short, on-point description beats a long catch-all one.
    """
    if not prompt_tokens or not desc_tokens:
        return 0.0
    inter = prompt_tokens & desc_tokens
    if not inter:
        return 0.0
    union = prompt_tokens | desc_tokens
    return len(inter) + (len(inter) / len(union))


def _load_module(name: str, path: str):
    spec = importlib.util.spec_from_file_location(name, path)
    if spec is None or spec.loader is None:
        raise RuntimeError(f"could not import {path}")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def load_plugins(repo: str) -> list[dict]:
    mf = os.path.join(repo, ".claude-plugin", "marketplace.json")
    with open(mf, encoding="utf-8") as fh:
        data = json.load(fh)
    out = []
    for p in data.get("plugins", []):
        name, desc = p.get("name"), p.get("description")
        if isinstance(name, str) and isinstance(desc, str):
            out.append({"name": name, "tokens": tokenize(desc)})
    return out


def load_targets(repo: str, scope: str = "plugin") -> list[dict]:
    """Load lexical routing targets.

    The original scorecard only ranked marketplace plugins. Self-learning also
    needs command/agent/skill attribution, so entity scorecards can opt into the
    catalog without changing the plugin-only default.
    """
    targets: list[dict[str, Any]] = []
    if scope in {"plugin", "all"}:
        for plugin in load_plugins(repo):
            targets.append({
                "type": "plugin",
                "name": plugin["name"],
                "tokens": plugin["tokens"],
            })
    if scope in {"entity", "all"}:
        catalog_path = os.path.join(os.path.dirname(os.path.abspath(__file__)), "legion-catalog.py")
        catalog = _load_module("legion_catalog_for_eval", catalog_path).build_catalog(repo)
        for entity in catalog.get("entities", []):
            if not isinstance(entity, dict):
                continue
            etype = entity.get("type")
            name = entity.get("name")
            desc = entity.get("description")
            if etype == "plugin" or not isinstance(name, str) or not isinstance(desc, str):
                continue
            tokens = tokenize(" ".join([etype or "", name, desc]))
            if tokens:
                targets.append({"type": etype, "name": name, "tokens": tokens})
    return targets


def rank(prompt: str, plugins: list[dict]) -> list[tuple[str, float]]:
    """Return [(plugin_name, score), …] sorted by score desc, then name."""
    pt = tokenize(prompt)
    scored = [(p["name"], score(pt, p["tokens"])) for p in plugins]
    scored.sort(key=lambda kv: (-kv[1], kv[0]))
    return scored


def _rank_details(prompt: str, targets: list[dict]) -> list[dict[str, Any]]:
    pt = tokenize(prompt)
    scored = [
        {
            "type": target.get("type") or "plugin",
            "name": target["name"],
            "score": score(pt, target["tokens"]),
        }
        for target in targets
    ]
    scored.sort(key=lambda item: (-item["score"], item["type"], item["name"]))
    return scored


def _target_matches(item: dict[str, Any], name: Any, target_type: Any = None) -> bool:
    if item.get("name") != name:
        return False
    if target_type:
        return item.get("type") == target_type
    return True


def evaluate_case(case: dict, plugins: list[dict], top_k: int, gap: float) -> dict:
    """Score one eval case. A case is {prompt, expect, [expect_not], [why]}."""
    ranked_details = _rank_details(case["prompt"], plugins)
    ranked = [(item["name"], item["score"]) for item in ranked_details]
    expect = case.get("expect")
    expect_type = case.get("expect_type") or "plugin"
    top = ranked_details[0] if ranked_details else {}
    top1 = top.get("name")
    top1_type = top.get("type")
    top1_score = top.get("score", 0.0)

    in_top1 = _target_matches(top, expect, expect_type)
    in_topk = any(_target_matches(item, expect, expect_type) for item in ranked_details[:top_k])
    # Collision: the expected plugin placed in the top-k but lost to a near-tie
    # winner — i.e. its score is within `gap` of the winner's. That's the
    # ambiguous zone where real (model) triggering becomes unreliable.
    expect_score = next(
        (
            item["score"]
            for item in ranked_details
            if _target_matches(item, expect, expect_type)
        ),
        0.0,
    )
    collision = in_topk and not in_top1 and (top1_score - expect_score) < gap
    # An anti-trigger that wrongly wins is a hard miss.
    expect_not = case.get("expect_not")
    expect_not_type = case.get("expect_not_type")
    false_trigger = bool(expect_not and _target_matches(top, expect_not, expect_not_type))

    status = "pass" if (in_top1 and not false_trigger) else (
        "collision" if collision else "miss")
    return {
        "prompt": case["prompt"],
        "expect": expect,
        "expect_type": expect_type,
        "got": top1,
        "got_type": top1_type,
        "in_top1": in_top1,
        "in_topk": in_topk,
        "collision": collision,
        "false_trigger": false_trigger,
        "status": status,
        "top": ranked[:top_k],
    }


def summarize(results: list[dict]) -> dict:
    n = len(results) or 1
    return {
        "cases": len(results),
        "pass": sum(r["status"] == "pass" for r in results),
        "collision": sum(r["status"] == "collision" for r in results),
        "miss": sum(r["status"] == "miss" for r in results),
        "precision_at_1": round(sum(r["in_top1"] for r in results) / n, 3),
        "hit_at_k": round(sum(r["in_topk"] for r in results) / n, 3),
    }


def _load_dataset(path: str) -> list[dict]:
    # YAML if available, else JSON. Keep stdlib-only by tolerating a missing yaml.
    text = open(path, encoding="utf-8").read()
    if path.endswith((".yaml", ".yml")):
        try:
            import yaml  # type: ignore
            return yaml.safe_load(text)["cases"]
        except ImportError:
            return _load_simple_cases_yaml(text)
    return json.loads(text)["cases"]


def _yaml_value(text: str) -> str:
    value = text.strip()
    if len(value) >= 2 and value[0] == value[-1] and value[0] in {"'", '"'}:
        try:
            if value[0] == '"':
                return json.loads(value)
        except ValueError:
            pass
        return value[1:-1]
    return value


def _load_simple_cases_yaml(text: str) -> list[dict]:
    """Tiny fallback parser for legion-observability/eval/*.yaml.

    It intentionally supports only the shipped eval shape:
    cases:
      - prompt: "..."
        expect: plugin
        expect_not: optional
        why: free text
    """
    cases: list[dict] = []
    current: dict | None = None
    in_cases = False
    for raw_line in text.splitlines():
        line = raw_line.split("#", 1)[0].rstrip()
        if not line.strip():
            continue
        if line.strip() == "cases:":
            in_cases = True
            continue
        if not in_cases:
            continue
        stripped = line.strip()
        if stripped.startswith("- "):
            if current:
                cases.append(current)
            current = {}
            stripped = stripped[2:].strip()
            if not stripped:
                continue
        if ":" not in stripped or current is None:
            continue
        key, value = stripped.split(":", 1)
        key = key.strip()
        if key in {"prompt", "expect", "expect_type", "expect_not", "expect_not_type", "why"}:
            current[key] = _yaml_value(value)
    if current:
        cases.append(current)
    return cases


def _scope_for_cases(cases: list[dict], requested: str) -> str:
    if requested != "auto":
        return requested
    target_types: set[str] = set()
    for case in cases:
        target_types.add(case.get("expect_type") or "plugin")
        if case.get("expect_not"):
            target_types.add(case.get("expect_not_type") or "plugin")
    has_plugin = "plugin" in target_types
    has_entity = any(target_type != "plugin" for target_type in target_types)
    if has_plugin and has_entity:
        return "all"
    return "entity" if has_entity else "plugin"


def main(argv: list[str]) -> int:
    ap = argparse.ArgumentParser(prog="legion-eval")
    here = os.path.dirname(os.path.abspath(__file__))
    default_repo = os.path.abspath(os.path.join(here, "..", ".."))
    ap.add_argument("--repo", default=default_repo)
    ap.add_argument("--dataset", default=os.path.join(
        here, "..", "eval", "skill-triggering.yaml"))
    ap.add_argument("--top-k", type=int, default=3)
    ap.add_argument("--gap", type=float, default=0.5)
    ap.add_argument("--scope", choices=["auto", "plugin", "entity", "all"], default="auto")
    ap.add_argument("--json", action="store_true")
    ap.add_argument("--explain", metavar="PROMPT")
    args = ap.parse_args(argv)

    cases = _load_dataset(args.dataset)
    targets = load_targets(args.repo, _scope_for_cases(cases, args.scope))

    if args.explain:
        ranked = _rank_details(args.explain, targets)[: args.top_k]
        for item in ranked:
            print(f"{item['score']:6.3f}  {item['type']}:{item['name']}")
        return 0

    results = [evaluate_case(c, targets, args.top_k, args.gap) for c in cases]
    summary = summarize(results)

    if args.json:
        print(json.dumps({"summary": summary, "results": results},
                         ensure_ascii=False))
        return 0

    print(f"legion-eval: {summary['cases']} cases  "
          f"P@1={summary['precision_at_1']}  hit@{args.top_k}={summary['hit_at_k']}  "
          f"({summary['pass']} pass, {summary['collision']} collision, "
          f"{summary['miss']} miss)")
    for r in results:
        if r["status"] != "pass":
            top = ", ".join(f"{n}({s:.2f})" for n, s in r["top"])
            print(f"  [{r['status']}] expect={r['expect']} got={r['got']}")
            print(f"      prompt: {r['prompt']}")
            print(f"      top:    {top}")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
