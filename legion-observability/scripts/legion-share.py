#!/usr/bin/env python3
"""legion-share — measure the codex-vs-primary split against a configurable target.

Reads legion.span.v1 telemetry (both codex delegations AND the primary's self-work,
logged via `legion-trace emit` / the synthetic primary baseline), computes codex's
share, and compares it to the target (routing.toml [targets].codex_share, or
$LEGION_TARGET_CODEX_SHARE, default 0.5).

Framing note: this controller is codex-vs-primary (the primary is whoever drives
the session; historically Opus). It stays valid for a non-codex primary; a full
N-executor share controller (per-executor targets) is a follow-up.

  legion-share            # JSON report: share by runs + tokens, per-model, status
  legion-share --window 7d --json
  legion-share next       # advisory recommendation for the next eligible task
  legion-share gate       # explicit opt-in enforcement; exit 1 when under target

Pure stdlib (tomllib, 3.11+). Importable for tests.
"""
import argparse
import glob
import json
import os
import re
import sys
import time
from datetime import datetime, timezone

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import legion_state  # noqa: E402

try:
    import tomllib
except ModuleNotFoundError:  # pragma: no cover
    tomllib = None

_STATE = legion_state.resolve_state(os.getcwd())
_DEF_SPANS = os.environ.get("LEGION_TELEMETRY_DIR", _STATE["telemetry_dir"])
_DEF_ROUTING = os.path.join(os.path.dirname(__file__), "..", "..", "legion-router", "config", "routing.toml")


def is_codex(executor):
    # codex, codex-review, codex-resume all count as codex/GPT work
    return str(executor or "").startswith("codex")


def _num(x):
    return x if isinstance(x, (int, float)) and not isinstance(x, bool) and x == x else 0


_WINDOW_SECONDS = {"s": 1, "m": 60, "h": 3600, "d": 86400, "w": 604800}
SUCCESS_STATUSES = {"ok", "over_budget"}


def parse_window(value):
    if not value:
        return None
    match = re.fullmatch(r"([1-9][0-9]*)([smhdw])", str(value).strip().lower())
    if not match:
        raise ValueError("window must be a positive duration such as 12h, 7d, or 2w")
    return int(match.group(1)) * _WINDOW_SECONDS[match.group(2)]


def _timestamp(value):
    if isinstance(value, (int, float)) and not isinstance(value, bool):
        return float(value)
    if not isinstance(value, str) or not value.strip():
        return None
    text = value.strip()
    if text.endswith("Z"):
        text = text[:-1] + "+00:00"
    try:
        parsed = datetime.fromisoformat(text)
    except ValueError:
        return None
    if parsed.tzinfo is None:
        parsed = parsed.replace(tzinfo=timezone.utc)
    return parsed.timestamp()


def load_spans(d, since=None):
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
                    timestamp = _timestamp(s.get("ts")) if isinstance(s, dict) else None
                    if (
                        isinstance(s, dict)
                        and s.get("schema") == "legion.span.v1"
                        and (since is None or (timestamp is not None and timestamp >= since))
                    ):
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


def is_synthetic_opus_baseline(s):
    # A delegate run emits a synthetic "what the PRIMARY would have cost" span.
    # Harness-generic: the historical `claude` primary value carries the
    # `synthetic_opus_baseline` marker; any primary also carries the generic
    # `synthetic_primary_baseline`. Accept either so old and new spans both filter.
    artifacts = s.get("artifacts") or {}
    if not isinstance(artifacts, dict):
        return False
    return artifacts.get("synthetic_opus_baseline") is True or artifacts.get("synthetic_primary_baseline") is True


def compute(spans):
    failed = sum(1 for s in spans if s.get("status") not in SUCCESS_STATUSES)
    ok = [
        s for s in spans if s.get("status") in SUCCESS_STATUSES
    ]  # share = usable work only (failed runs do not count)
    if any((not is_codex(s.get("executor"))) and not is_synthetic_opus_baseline(s) for s in ok):
        ok = [s for s in ok if not is_synthetic_opus_baseline(s)]
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


def gate(c, tgt):
    """Opt-in enforcement surface: turn the measured share into
    a one-line directive + exit code. Exit code 1 means "under target — delegate
    the next eligible slice to codex"; 0 means no action (on balance, no data yet,
    or unmeasurable). Normal reports and `next` remain advisory; a repository or
    CI job must explicitly invoke this command to enforce its configured target.
    """
    runs, share = c["total_runs"], c["codex_share_runs"]
    pct, tpct = round(share * 100), round(tgt * 100)
    if c["codex_runs"] > 0 and c["opus_runs"] == 0:
        return ("legion-share: only codex work is logged — Opus self-work isn't being "
                "recorded, so the share is unmeasurable.", 0)
    if runs == 0:
        return ("legion-share: no work logged yet.", 0)
    if share < tgt:
        return (f"legion-share: codex share {pct}% < {tpct}% target — route the next eligible "
                f"(mechanical / bulk / parallelizable / second-opinion) slice to codex via "
                f"`legion-delegate` instead of doing it inline.", 1)
    return (f"legion-share: codex share {pct}% >= {tpct}% target — on balance.", 0)


def main(argv=None):
    ap = argparse.ArgumentParser(description="Measure + drive the codex work share.")
    ap.add_argument("cmd", nargs="?", default="report", choices=["report", "next", "gate"])
    ap.add_argument("--dir", default=_DEF_SPANS)
    ap.add_argument("--routing", default=_DEF_ROUTING)
    ap.add_argument("--target", type=float, default=None)
    ap.add_argument("--window", default=None, help="measurement window, e.g. 12h, 7d, or 2w")
    ap.add_argument("--json", action="store_true", help="accepted for report compatibility; report output is JSON by default")
    a = ap.parse_args(argv)
    try:
        window_seconds = parse_window(a.window)
    except ValueError as exc:
        ap.error(str(exc))
    since = time.time() - window_seconds if window_seconds is not None else None
    c = compute(load_spans(a.dir, since=since))
    tgt = target_share(a.target, a.routing)
    if a.cmd == "next":
        print(recommend_next(c["codex_share_runs"], c["total_runs"], tgt))
        return 0
    if a.cmd == "gate":
        line, code = gate(c, tgt)
        print(line)
        return code
    c["target"] = tgt
    c["window"] = a.window or "all"
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
