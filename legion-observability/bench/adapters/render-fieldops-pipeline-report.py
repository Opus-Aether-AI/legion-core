#!/usr/bin/env python3
"""Render the FieldOps e2e benchmark artifacts as one demo-friendly HTML report."""

from __future__ import annotations

import argparse
import html
import json
import os
from typing import Any


ARTIFACTS = [
    "doctor.json",
    "route-implement.json",
    "route-review.json",
    "fanout.json",
    "review.json",
    "score.json",
    "legion-report.json",
    "legion-observability.html",
    "legion-share.json",
    "self-learn-record.json",
    "self-learn-hints.json",
    "self-learn-run.json",
    "heal-plan.json",
    "bench-core.json",
]


def _read_json(path: str, default: Any) -> Any:
    try:
        with open(path, encoding="utf-8") as handle:
            return json.load(handle)
    except (OSError, ValueError, TypeError):
        return default


def _read_text(path: str, limit: int | None = None) -> str:
    try:
        with open(path, encoding="utf-8") as handle:
            text = handle.read()
    except OSError:
        return ""
    return text if limit is None else text[:limit]


def _num(value: Any) -> float:
    if isinstance(value, bool):
        return 0.0
    if isinstance(value, (int, float)) and value == value:
        return float(value)
    return 0.0


def _int(value: Any) -> int:
    return int(_num(value))


def _pct(value: Any) -> str:
    return f"{_num(value) * 100:.1f}%"


def _money(value: Any) -> str:
    return f"${_num(value):,.4f}"


def _json_pretty(value: Any) -> str:
    return json.dumps(value, indent=2, sort_keys=True, ensure_ascii=False)


def _esc(value: Any) -> str:
    return html.escape(str(value))


def _badge(ok: bool, label: str | None = None) -> str:
    text = label or ("PASS" if ok else "FAIL")
    klass = "good" if ok else "bad"
    return f'<span class="badge {klass}">{_esc(text)}</span>'


def _stage(name: str, command: str, ok: bool, proof: str, artifact: str) -> str:
    return (
        "<tr>"
        f"<td><strong>{_esc(name)}</strong></td>"
        f"<td><code>{_esc(command)}</code></td>"
        f"<td>{_badge(ok)}</td>"
        f"<td>{_esc(proof)}</td>"
        f"<td><code>{_esc(artifact)}</code></td>"
        "</tr>"
    )


def _details(title: str, body: str, *, open_by_default: bool = False) -> str:
    opened = " open" if open_by_default else ""
    return (
        f"<details{opened}>"
        f"<summary>{_esc(title)}</summary>"
        f"<pre>{html.escape(body)}</pre>"
        "</details>"
    )


def _doctor_counts(doctor: Any) -> dict[str, int]:
    counts = {"pass": 0, "warn": 0, "fail": 0}
    if not isinstance(doctor, list):
        return counts
    for item in doctor:
        severity = str(item.get("severity", "")) if isinstance(item, dict) else ""
        if severity in counts:
            counts[severity] += 1
    return counts


def _artifact_path(workspace: str, name: str) -> str:
    return os.path.join(workspace, name)


def build_report(workspace: str, task_file: str) -> str:
    task = _read_text(task_file)
    doctor = _read_json(_artifact_path(workspace, "doctor.json"), [])
    route_implement = _read_json(_artifact_path(workspace, "route-implement.json"), {})
    route_review = _read_json(_artifact_path(workspace, "route-review.json"), {})
    fanout = _read_json(_artifact_path(workspace, "fanout.json"), {})
    review = _read_json(_artifact_path(workspace, "review.json"), {})
    score = _read_json(_artifact_path(workspace, "score.json"), {})
    report = _read_json(_artifact_path(workspace, "legion-report.json"), {})
    share = _read_json(_artifact_path(workspace, "legion-share.json"), {})
    self_record = _read_json(_artifact_path(workspace, "self-learn-record.json"), {})
    self_hints = _read_json(_artifact_path(workspace, "self-learn-hints.json"), {})
    self_run = _read_json(_artifact_path(workspace, "self-learn-run.json"), {})
    heal = _read_json(_artifact_path(workspace, "heal-plan.json"), {})
    bench = _read_json(_artifact_path(workspace, "bench-core.json"), {})
    implementation = _read_text(_artifact_path(workspace, "fieldops_triage.py"))

    fanout_results = fanout.get("results") if isinstance(fanout.get("results"), list) else []
    diff_path = ""
    if fanout_results and isinstance(fanout_results[0], dict):
        diff_path = str(fanout_results[0].get("diff_path") or "")
    diff_text = _read_text(diff_path) if diff_path else ""
    doctor_counts = _doctor_counts(doctor)
    report_total = report.get("total", {}) if isinstance(report.get("total"), dict) else {}
    report_groups = report.get("groups", {}) if isinstance(report.get("groups"), dict) else {}
    bench_summary = bench.get("summary", {}) if isinstance(bench.get("summary"), dict) else {}
    bench_metrics = bench_summary.get("metrics", {}) if isinstance(bench_summary.get("metrics"), dict) else {}
    self_scorecard = self_run.get("scorecard", {}) if isinstance(self_run.get("scorecard"), dict) else {}
    self_summary = self_run.get("summary", {}) if isinstance(self_run.get("summary"), dict) else {}

    pipeline_ok = all(
        [
            doctor_counts["fail"] == 0,
            bool(route_implement.get("resolved")),
            bool(route_review.get("resolved")),
            _int(fanout.get("failed")) == 0,
            _int(fanout.get("applied")) >= 1,
            review.get("status") == "ok",
            score.get("passed") is True,
            _num(report_total.get("success_rate")) == 1.0,
            _int(share.get("failed_runs")) == 0,
            self_run.get("applied_memory") is True,
            _int(heal.get("total")) == 0,
            bench_summary.get("ok") is True,
        ]
    )

    stage_rows = [
        _stage(
            "Doctor",
            "legion-doctor --strict-demo",
            doctor_counts["fail"] == 0,
            f"{doctor_counts['pass']} pass, {doctor_counts['warn']} warn, {doctor_counts['fail']} fail",
            "doctor.json",
        ),
        _stage(
            "Route implementation",
            "legion-route implement-feature",
            bool(route_implement.get("resolved")),
            f"{route_implement.get('executor', 'unknown')} / {route_implement.get('model', 'unknown')} / {route_implement.get('sandbox', 'unknown')}",
            "route-implement.json",
        ),
        _stage(
            "Route review",
            "legion-route final-review",
            bool(route_review.get("resolved")),
            f"{route_review.get('executor', 'unknown')} / {route_review.get('model', 'unknown')}",
            "route-review.json",
        ),
        _stage(
            "Fanout + apply",
            "legion-fanout --apply",
            _int(fanout.get("failed")) == 0 and _int(fanout.get("applied")) >= 1,
            f"slices={_int(fanout.get('slices'))}, ok={_int(fanout.get('ok'))}, applied={_int(fanout.get('applied'))}, conflicts={_int(fanout.get('apply_conflicts'))}",
            "fanout.json",
        ),
        _stage(
            "Final review",
            "legion-delegate review",
            review.get("status") == "ok",
            f"{review.get('model', 'unknown')} returned {review.get('status', 'unknown')}",
            "review.json",
        ),
        _stage(
            "Golden eval",
            "python3 eval_fieldops_triage.py",
            score.get("passed") is True,
            f"{_int(score.get('score'))}/{_int(score.get('total'))} cases passed",
            "score.json",
        ),
        _stage(
            "Observability",
            "legion-report --trace latest",
            _num(report_total.get("success_rate")) == 1.0,
            f"{_int(report_total.get('ok'))}/{_int(report_total.get('count'))} spans ok, cost {_money(report_total.get('cost_usd'))}",
            "legion-report.json + legion-observability.html",
        ),
        _stage(
            "Share",
            "legion-share --window 1d",
            _int(share.get("failed_runs")) == 0,
            f"status={share.get('status', 'unknown')}, codex_runs={share.get('codex_runs', 0)}, failed_runs={share.get('failed_runs', 0)}",
            "legion-share.json",
        ),
        _stage(
            "Self-learn",
            "legion-self-learn record + run",
            self_run.get("applied_memory") is True,
            f"memory={self_run.get('applied_memory')}, outcomes={self_summary.get('outcomes', 0)}, scorecard_ok={self_scorecard.get('ok')}",
            "self-learn-*.json",
        ),
        _stage(
            "Heal",
            "legion-heal plan",
            _int(heal.get("total")) == 0,
            f"findings={_int(heal.get('total'))}, fixable={_int(heal.get('fixable'))}",
            "heal-plan.json",
        ),
        _stage(
            "Nested core bench",
            "legion-bench run --suite core --strict",
            bench_summary.get("ok") is True,
            f"pass={_int(bench_metrics.get('pass'))}, fail={_int(bench_metrics.get('fail'))}",
            "bench-core.json",
        ),
    ]

    group_rows = []
    for name, item in sorted(report_groups.items()):
        if not isinstance(item, dict):
            continue
        group_rows.append(
            "<tr>"
            f"<td><strong>{_esc(name)}</strong></td>"
            f"<td>{_int(item.get('count'))}</td>"
            f"<td>{_int(item.get('ok'))}</td>"
            f"<td>{_pct(item.get('success_rate'))}</td>"
            f"<td>{_money(item.get('cost_usd'))}</td>"
            f"<td>{_int(item.get('p50_ms'))}</td>"
            f"<td>{_int(item.get('p95_ms'))}</td>"
            "</tr>"
        )

    artifact_rows = []
    for name in ARTIFACTS:
        path = _artifact_path(workspace, name)
        exists = os.path.exists(path)
        size = os.path.getsize(path) if exists else 0
        artifact_rows.append(
            "<tr>"
            f"<td><code>{_esc(name)}</code></td>"
            f"<td>{_badge(exists, 'present' if exists else 'missing')}</td>"
            f"<td>{size:,} bytes</td>"
            f"<td><code>{_esc(path)}</code></td>"
            "</tr>"
        )

    raw_sections = []
    raw_payloads = {
        "doctor.json": doctor,
        "route-implement.json": route_implement,
        "route-review.json": route_review,
        "fanout.json": fanout,
        "review.json": review,
        "score.json": score,
        "legion-report.json": report,
        "legion-share.json": share,
        "self-learn-record.json": self_record,
        "self-learn-hints.json": self_hints,
        "self-learn-run.json": self_run,
        "heal-plan.json": heal,
        "bench-core.json": bench,
    }
    for name, payload in raw_payloads.items():
        raw_sections.append(_details(name, _json_pretty(payload)))

    by_entity = self_run.get("by_entity") if isinstance(self_run.get("by_entity"), dict) else {}
    implementation_section = _details("Applied implementation: fieldops_triage.py", implementation)
    diff_section = _details("Applied diff from Legion delegate", diff_text or "No diff file found.")

    return f"""<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>Legion Full Pipeline Report</title>
  <style>
    :root {{
      --bg: #f5f7fb;
      --panel: #ffffff;
      --text: #172033;
      --muted: #667085;
      --line: #d9e0ec;
      --blue: #2454d6;
      --green: #087f5b;
      --red: #b42318;
      --amber: #b54708;
      --ink: #101828;
    }}
    * {{ box-sizing: border-box; }}
    body {{ margin: 0; background: var(--bg); color: var(--text); font: 14px/1.5 -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif; }}
    main {{ max-width: 1180px; margin: 0 auto; padding: 32px 20px 52px; }}
    .hero {{ border-bottom: 1px solid var(--line); padding-bottom: 18px; margin-bottom: 18px; }}
    .eyebrow {{ margin: 0 0 6px; color: var(--blue); font-size: 12px; font-weight: 800; letter-spacing: 0; text-transform: uppercase; }}
    h1 {{ margin: 0; font-size: 30px; line-height: 1.2; }}
    h2 {{ margin: 0; font-size: 18px; }}
    h3 {{ margin: 0 0 8px; font-size: 15px; }}
    p {{ margin: 0; }}
    .subtle {{ color: var(--muted); }}
    .grid {{ display: grid; gap: 12px; }}
    .cards {{ grid-template-columns: repeat(4, minmax(0, 1fr)); margin: 16px 0; }}
    .card, .panel {{ background: var(--panel); border: 1px solid var(--line); border-radius: 8px; box-shadow: 0 1px 2px rgba(16,24,40,.04); }}
    .card {{ padding: 14px; }}
    .card span {{ display: block; color: var(--muted); font-size: 12px; }}
    .card strong {{ display: block; margin-top: 4px; font-size: 24px; line-height: 1.1; }}
    .panel {{ margin-top: 14px; overflow: hidden; }}
    .panel-head {{ display: flex; justify-content: space-between; gap: 16px; align-items: center; padding: 14px 16px; border-bottom: 1px solid var(--line); }}
    .panel-body {{ padding: 16px; }}
    .table-wrap {{ overflow-x: auto; }}
    table {{ width: 100%; border-collapse: collapse; min-width: 820px; }}
    th, td {{ padding: 10px 12px; border-bottom: 1px solid var(--line); vertical-align: top; }}
    th {{ color: var(--muted); font-size: 12px; text-align: left; text-transform: uppercase; }}
    td {{ text-align: left; }}
    code {{ font: 12px ui-monospace, SFMono-Regular, Menlo, Consolas, monospace; color: var(--ink); }}
    pre {{ overflow: auto; max-height: 520px; margin: 10px 0 0; padding: 12px; background: #0f172a; color: #e5e7eb; border-radius: 8px; font: 12px/1.45 ui-monospace, SFMono-Regular, Menlo, Consolas, monospace; }}
    details {{ margin: 10px 0; }}
    summary {{ cursor: pointer; font-weight: 700; }}
    .badge {{ display: inline-block; border-radius: 999px; padding: 3px 9px; font-size: 12px; font-weight: 800; }}
    .good {{ color: var(--green); background: #dff8ea; }}
    .bad {{ color: var(--red); background: #fee4e2; }}
    .warn {{ color: var(--amber); background: #fef0c7; }}
    .task {{ white-space: pre-wrap; padding: 12px; background: #f8fafc; border: 1px solid var(--line); border-radius: 8px; }}
    @media (max-width: 820px) {{ main {{ padding: 22px 12px 36px; }} .cards {{ grid-template-columns: repeat(2, minmax(0, 1fr)); }} h1 {{ font-size: 24px; }} }}
  </style>
</head>
<body>
  <main>
    <section class="hero">
      <p class="eyebrow">Legion benchmark evidence</p>
      <h1>Legion Full Pipeline Report</h1>
      <p class="subtle">One FieldOps coding task run through route, fanout, apply, review, eval, observability, share, self-learn, heal, and nested core bench.</p>
    </section>

    <section class="grid cards" aria-label="Pipeline summary">
      <div class="card"><span>Pipeline</span><strong>{'PASS' if pipeline_ok else 'FAIL'}</strong></div>
      <div class="card"><span>Golden eval</span><strong>{_int(score.get('score'))}/{_int(score.get('total'))}</strong></div>
      <div class="card"><span>Spans ok</span><strong>{_int(report_total.get('ok'))}/{_int(report_total.get('count'))}</strong></div>
      <div class="card"><span>Total cost</span><strong>{_money(report_total.get('cost_usd'))}</strong></div>
    </section>

    <section class="panel">
      <div class="panel-head"><h2>Task</h2><span>{_badge(score.get('passed') is True)}</span></div>
      <div class="panel-body"><div class="task">{_esc(task)}</div></div>
    </section>

    <section class="panel">
      <div class="panel-head"><h2>Pipeline Timeline</h2><p class="subtle">Every stage and its proof artifact.</p></div>
      <div class="table-wrap">
        <table>
          <thead><tr><th>Stage</th><th>Command</th><th>Status</th><th>Proof</th><th>Artifact</th></tr></thead>
          <tbody>{''.join(stage_rows)}</tbody>
        </table>
      </div>
    </section>

    <section class="panel">
      <div class="panel-head"><h2>Observability</h2><p class="subtle">Raw telemetry table is also saved as <code>legion-observability.html</code>.</p></div>
      <div class="table-wrap">
        <table>
          <thead><tr><th>Executor</th><th>Runs</th><th>OK</th><th>Success</th><th>Cost</th><th>P50 ms</th><th>P95 ms</th></tr></thead>
          <tbody>{''.join(group_rows)}</tbody>
        </table>
      </div>
    </section>

    <section class="panel">
      <div class="panel-head"><h2>Self-learn + Heal</h2><p class="subtle">Shows whether Legion stored a lesson and whether doctor/heal found repairs.</p></div>
      <div class="panel-body">
        <p><strong>Outcome recorded:</strong> {_esc(self_record.get('target_type', ''))}:{_esc(self_record.get('target_name', ''))}</p>
        <p><strong>Memory applied:</strong> {_esc(self_run.get('applied_memory'))}; <strong>by entity:</strong> <code>{_esc(by_entity)}</code></p>
        <p><strong>Scorecard:</strong> {_esc(self_scorecard.get('ok'))}; <strong>heal findings:</strong> {_int(heal.get('total'))}</p>
      </div>
    </section>

    <section class="panel">
      <div class="panel-head"><h2>Generated Code</h2><p class="subtle">The implementation Legion produced and the diff it applied.</p></div>
      <div class="panel-body">{implementation_section}{diff_section}</div>
    </section>

    <section class="panel">
      <div class="panel-head"><h2>Artifacts</h2><p class="subtle">Files produced by this one benchmark run.</p></div>
      <div class="table-wrap">
        <table>
          <thead><tr><th>Artifact</th><th>Status</th><th>Size</th><th>Path</th></tr></thead>
          <tbody>{''.join(artifact_rows)}</tbody>
        </table>
      </div>
    </section>

    <section class="panel">
      <div class="panel-head"><h2>Raw JSON Evidence</h2><p class="subtle">All pipeline outputs embedded for inspection.</p></div>
      <div class="panel-body">{''.join(raw_sections)}</div>
    </section>
  </main>
</body>
</html>"""


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--workspace", required=True)
    parser.add_argument("--task-file", required=True)
    parser.add_argument("--output", required=True)
    args = parser.parse_args()

    html_report = build_report(os.path.abspath(args.workspace), os.path.abspath(args.task_file))
    os.makedirs(os.path.dirname(os.path.abspath(args.output)), exist_ok=True)
    with open(args.output, "w", encoding="utf-8") as handle:
        handle.write(html_report)
        handle.write("\n")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
