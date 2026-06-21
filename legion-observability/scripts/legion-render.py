#!/usr/bin/env python3
"""legion-render — render a legion-aggregate result (stdin JSON) as a TUI table or HTML."""
import argparse
import html
import json
import sys


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
    rows = "".join(
        f'<tr><td>{html.escape(k)}</td><td>{v.get("count",0)}</td>'
        f'<td>{v.get("success_rate",0)*100:.1f}%</td><td>${v.get("cost_usd",0):.4f}</td>'
        f'<td>{v.get("p50_ms",0):.0f}</td><td>{v.get("p95_ms",0):.0f}</td></tr>'
        for k, v in sorted(g.items())
    )
    return (
        '<!doctype html><meta charset="utf-8"><title>Legion report</title>'
        "<style>body{font:14px system-ui;margin:2rem}table{border-collapse:collapse}"
        "td,th{border:1px solid #ddd;padding:.4rem .8rem;text-align:right}"
        "td:first-child,th:first-child{text-align:left}</style>"
        f'<table><caption>Legion — by {html.escape(by)}</caption>'
        f'<tr><th>{html.escape(by)}</th><th>runs</th><th>success</th><th>cost</th>'
        "<th>p50 ms</th><th>p95 ms</th></tr>"
        f"{rows}"
        f'<tr><th>TOTAL</th><th>{t.get("count",0)}</th><th>{t.get("success_rate",0)*100:.1f}%</th>'
        f'<th>${t.get("cost_usd",0):.4f}</th><th></th><th></th></tr></table>'
    )


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
