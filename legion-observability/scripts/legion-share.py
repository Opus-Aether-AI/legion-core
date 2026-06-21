#!/usr/bin/env python3
"""legion-share — measure the codex-vs-Opus work split and drive it toward target.

Reads legion.span.v1 telemetry (both codex delegations AND Opus self-work, which Opus
logs via `legion-trace emit --executor opus ...`), computes codex's share, and compares
it to the target (routing.toml [targets].codex_share, or $LEGION_TARGET_CODEX_SHARE,
default 0.5).

  legion-share            # JSON report: share by runs + tokens, per-model, status
  legion-share next       # -> "codex" or "opus": who should do the NEXT task to converge

Pure stdlib (tomllib, 3.11+). Importable for tests.
"""
import argparse
import glob
import json
import os
import sys

try:
    import tomllib
except ModuleNotFoundError:  # pragma: no cover
    tomllib = None

_DEF_SPANS = os.environ.get("LEGION_TELEMETRY_DIR", os.path.expanduser("~/.claude/logs/legion/spans"))
_DEF_ROUTING = os.path.join(os.path.dirname(__file__), "..", "..", "legion-router", "config", "routing.toml")


def is_codex(executor):
    # codex, codex-review, codex-resume all count as codex/GPT work
    return str(executor or "").startswith("codex")


def _num(x):
    return x if isinstance(x, (int, float)) and not isinstance(x, bool) and x == x else 0


def load_spans(d):
    spans = []
    for p in sorted(glob.glob(os.path.join(d, "*.jsonl"))):
        try:
            with open(p) as fh:
                for line in fh:
                    line = line.strip()
                    if not line:
                        continue
                    try:
                        s = json.loads(line)
                    except (ValueError, TypeError):
                        continue
                    if isinstance(s, dict) and s.get("schema") == "legion.span.v1":
                        spans.append(s)
        except OSError:
            continue
    return spans


def target_share(explicit=None, routing=_DEF_ROUTING):
    val = None
    if explicit is not None:
        val = explicit
    else:
        env = os.environ.get("LEGION_TARGET_CODEX_SHARE")
        if env:
            try:
                val = float(env)
            except ValueError:
                val = None
        if val is None and tomllib and routing and os.path.exists(routing):
            try:
                with open(routing, "rb") as fh:
                    val = float((tomllib.load(fh).get("targets") or {}).get("codex_share", 0.5))
            except (OSError, ValueError, TypeError):
                val = None
    if val is None:
        val = 0.5
    return max(0.0, min(1.0, val))   # clamp — a typo'd target can't silently disable the controller


def _out_tokens(s):
    # GPT emits reasoning_output_tokens SEPARATELY from output_tokens; both are generated work.
    t = s.get("tokens") or {}
    return _num(t.get("output_tokens", 0)) + _num(t.get("reasoning_output_tokens", 0))


def compute(spans):
    failed = sum(1 for s in spans if s.get("status") != "ok")
    ok = [s for s in spans if s.get("status") == "ok"]   # share = successful work only (failures don't count)
    runs = len(ok)
    codex = sum(1 for s in ok if is_codex(s.get("executor")))
    codex_tok = sum(_out_tokens(s) for s in ok if is_codex(s.get("executor")))
    tot_tok = sum(_out_tokens(s) for s in ok)
    by_model = {}
    for s in ok:
        m = s.get("model", "?")
        by_model[m] = by_model.get(m, 0) + 1
    return {
        "total_runs": runs,
        "codex_runs": codex,
        "opus_runs": runs - codex,
        "failed_runs": failed,
        "codex_share_runs": round(codex / runs, 4) if runs else 0.0,
        "codex_share_tokens": round(codex_tok / tot_tok, 4) if tot_tok else 0.0,
        "by_model": dict(sorted(by_model.items(), key=lambda kv: -kv[1])),
    }


def recommend_next(share_runs, total_runs, target):
    # With no history, or below target, push the next eligible task to codex; else Opus.
    return "codex" if (total_runs == 0 or share_runs < target) else "opus"


def main(argv=None):
    ap = argparse.ArgumentParser(description="Measure + drive the codex work share.")
    ap.add_argument("cmd", nargs="?", default="report", choices=["report", "next"])
    ap.add_argument("--dir", default=_DEF_SPANS)
    ap.add_argument("--routing", default=_DEF_ROUTING)
    ap.add_argument("--target", type=float, default=None)
    a = ap.parse_args(argv)
    c = compute(load_spans(a.dir))
    tgt = target_share(a.target, a.routing)
    if a.cmd == "next":
        print(recommend_next(c["codex_share_runs"], c["total_runs"], tgt))
        return 0
    c["target"] = tgt
    # The share is only meaningful if BOTH sides are logged. An all-codex corpus means
    # Opus isn't logging its self-work — report that honestly instead of a false "met".
    if c["codex_runs"] > 0 and c["opus_runs"] == 0:
        c["status"] = "no_opus_baseline"
        sys.stderr.write(
            "legion-share: no Opus self-work logged — the share is unmeasurable until Opus logs "
            "its own tasks via `legion-trace emit --executor opus ...`\n")
    else:
        c["status"] = "met" if c["codex_share_runs"] >= tgt else "under"
    print(json.dumps(c, indent=2))
    return 0


if __name__ == "__main__":
    sys.exit(main())
