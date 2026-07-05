#!/usr/bin/env python3
"""legion-render — render a legion-aggregate result (stdin JSON) as a TUI table or HTML."""
import argparse
import html
import json
import sys


def _num(value):
    if isinstance(value, bool):
        return 0.0
    if isinstance(value, (int, float)) and value == value:
        return float(value)
    return 0.0


def _fmt_int(value):
    return f"{_num(value):,.0f}"


def _fmt_money(value):
    return f"${_num(value):,.4f}"


def _fmt_pct(value):
    return f"{_num(value) * 100:.1f}%"


def tui(d):
    g, t, by = d.get("groups", {}), d.get("total", {}), d.get("by", "executor")
    out = [f"Legion — by {by}"]
    out.append(f'{by.upper():<22}{"RUNS":>6}{"OK":>5}{"SUCCESS":>9}{"COST$":>12}{"P50ms":>9}{"P95ms":>9}')
    for k, v in sorted(g.items()):
        out.append(
            f'{k:<22}{v.get("count",0):>6}{v.get("ok",0):>5}{v.get("success_rate",0)*100:>8.1f}%'
            f'{v.get("cost_usd",0):>12.4f}{v.get("p50_ms",0):>9.0f}{v.get("p95_ms",0):>9.0f}'
        )
    out.append(
        f'{"TOTAL":<22}{t.get("count",0):>6}{t.get("ok",0):>5}'
        f'{t.get("success_rate",0)*100:>8.1f}%{t.get("cost_usd",0):>12.4f}'
    )
    return "\n".join(out)


def to_html(d):
    g, t, by = d.get("groups", {}), d.get("total", {}), d.get("by", "executor")
    rows = []
    for k, v in sorted(g.items()):
        rate = _num(v.get("success_rate", 0))
        tone = "good" if rate >= 1 else "warn" if rate > 0 else "bad"
        rows.append(
            "<tr>"
            f"<td><strong>{html.escape(str(k))}</strong></td>"
            f"<td>{_fmt_int(v.get('count', 0))}</td>"
            f"<td>{_fmt_int(v.get('ok', 0))}</td>"
            f'<td><span class="status-pill {tone}">{_fmt_pct(rate)}</span></td>'
            f"<td>{_fmt_money(v.get('cost_usd', 0))}</td>"
            f"<td>{_fmt_int(v.get('p50_ms', 0))}</td>"
            f"<td>{_fmt_int(v.get('p95_ms', 0))}</td>"
            "</tr>"
        )
    return f"""<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>Legion Observability Report</title>
  <style>
    :root {{
      color-scheme: light;
      --bg: #f6f7fb;
      --panel: #ffffff;
      --text: #1f2937;
      --muted: #64748b;
      --line: #d9dee8;
      --blue: #2563eb;
      --green: #0f766e;
      --amber: #b45309;
      --red: #b91c1c;
    }}
    * {{ box-sizing: border-box; }}
    body {{
      margin: 0;
      background: var(--bg);
      color: var(--text);
      font: 14px/1.5 -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif;
    }}
    main {{ max-width: 1040px; margin: 0 auto; padding: 32px 20px 44px; }}
    .hero {{
      border-bottom: 1px solid var(--line);
      padding-bottom: 18px;
      margin-bottom: 20px;
    }}
    .eyebrow {{
      margin: 0 0 6px;
      color: var(--blue);
      font-size: 12px;
      font-weight: 700;
      letter-spacing: 0;
      text-transform: uppercase;
    }}
    h1 {{ margin: 0; font-size: 28px; line-height: 1.2; }}
    .hero p:last-child {{ max-width: 720px; margin: 8px 0 0; color: var(--muted); }}
    .metric-grid {{
      display: grid;
      grid-template-columns: repeat(4, minmax(0, 1fr));
      gap: 12px;
      margin-bottom: 16px;
    }}
    .metric, .panel {{
      background: var(--panel);
      border: 1px solid var(--line);
      border-radius: 8px;
      box-shadow: 0 1px 2px rgba(15, 23, 42, .04);
    }}
    .metric {{ padding: 14px; }}
    .metric span {{ display: block; color: var(--muted); font-size: 12px; }}
    .metric strong {{ display: block; margin-top: 4px; font-size: 24px; line-height: 1.1; }}
    .panel {{ overflow: hidden; }}
    .panel-header {{
      display: flex;
      justify-content: space-between;
      gap: 16px;
      align-items: center;
      padding: 14px 16px;
      border-bottom: 1px solid var(--line);
    }}
    .panel-header h2 {{ margin: 0; font-size: 16px; }}
    .panel-header p {{ margin: 0; color: var(--muted); font-size: 12px; }}
    .table-wrap {{ overflow-x: auto; }}
    table {{ width: 100%; border-collapse: collapse; min-width: 680px; }}
    th, td {{ padding: 11px 14px; text-align: right; border-bottom: 1px solid var(--line); }}
    th:first-child, td:first-child {{ text-align: left; }}
    th {{ color: var(--muted); font-size: 12px; font-weight: 700; text-transform: uppercase; }}
    tbody tr:hover {{ background: #f8fafc; }}
    tfoot th {{ color: var(--text); background: #eef2f7; }}
    .status-pill {{
      display: inline-block;
      min-width: 64px;
      border-radius: 999px;
      padding: 3px 9px;
      font-weight: 700;
      text-align: center;
    }}
    .good {{ color: var(--green); background: #dcfce7; }}
    .warn {{ color: var(--amber); background: #fef3c7; }}
    .bad {{ color: var(--red); background: #fee2e2; }}
    @media (max-width: 760px) {{
      main {{ padding: 22px 12px 32px; }}
      .metric-grid {{ grid-template-columns: repeat(2, minmax(0, 1fr)); }}
      h1 {{ font-size: 24px; }}
    }}
  </style>
</head>
<body>
  <main>
    <section class="hero">
      <p class="eyebrow">Legion observability</p>
      <h1>Legion Observability Report</h1>
      <p>Grouped by {html.escape(str(by))}. Generated from legion.span.v1 telemetry so you can see cost, success, and latency at a glance.</p>
    </section>
    <section class="metric-grid" aria-label="Run summary">
      <div class="metric"><span>Total runs</span><strong>{_fmt_int(t.get("count", 0))}</strong></div>
      <div class="metric"><span>Successful runs</span><strong>{_fmt_int(t.get("ok", 0))}</strong></div>
      <div class="metric"><span>Success rate</span><strong>{_fmt_pct(t.get("success_rate", 0))}</strong></div>
      <div class="metric"><span>Total cost</span><strong>{_fmt_money(t.get("cost_usd", 0))}</strong></div>
    </section>
    <section class="panel">
      <div class="panel-header">
        <h2>Breakdown by {html.escape(str(by))}</h2>
        <p>{len(g)} groups</p>
      </div>
      <div class="table-wrap">
        <table>
          <thead>
            <tr><th>{html.escape(str(by))}</th><th>runs</th><th>ok</th><th>success</th><th>cost</th><th>p50 ms</th><th>p95 ms</th></tr>
          </thead>
          <tbody>{''.join(rows)}</tbody>
          <tfoot>
            <tr><th>Total</th><th>{_fmt_int(t.get("count", 0))}</th><th>{_fmt_int(t.get("ok", 0))}</th><th>{_fmt_pct(t.get("success_rate", 0))}</th><th>{_fmt_money(t.get("cost_usd", 0))}</th><th></th><th></th></tr>
          </tfoot>
        </table>
      </div>
    </section>
  </main>
</body>
</html>"""


def main(argv=None):
    ap = argparse.ArgumentParser()
    ap.add_argument("--html", action="store_true")
    a = ap.parse_args(argv)
    try:
        d = json.load(sys.stdin)
    except (ValueError, TypeError):
        sys.stderr.write("legion-render: expected aggregate JSON on stdin\n")
        return 1
    print(to_html(d) if a.html else tui(d))
    return 0


if __name__ == "__main__":
    sys.exit(main())
