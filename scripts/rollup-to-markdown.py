#!/usr/bin/env python3

import argparse
import pathlib
import re
import sys


TOTAL_RE = re.compile(r"^# total bytes:\s+(\d+)$")


def read_rollup(path):
    total = None
    rows = []
    for raw in path.read_text().splitlines():
        m = TOTAL_RE.match(raw)
        if m:
            total = int(m.group(1))
            continue
        if not raw or raw.startswith("#"):
            continue
        parts = raw.split("\t")
        if len(parts) < 6:
            continue
        bucket, bytes_s, pct_s, symbols_s, icf_s, clones_s = parts[:6]
        try:
            rows.append({
                "bucket": bucket,
                "bytes": int(bytes_s),
                "percent": float(pct_s),
                "symbols": int(symbols_s),
                "icf": int(icf_s),
                "clones": int(clones_s),
            })
        except ValueError:
            continue
    return total, rows


def read_budget_status(path):
    if path is None or not path.exists():
        return []
    rows = []
    for raw in path.read_text().splitlines():
        if not raw or raw.startswith("#"):
            continue
        parts = raw.split("\t")
        if len(parts) < 6:
            continue
        bucket, actual, limit, band, delta, status = parts[:6]
        rows.append({
            "bucket": bucket,
            "actual": actual,
            "limit": limit,
            "band": band,
            "delta": delta,
            "status": status,
        })
    return rows


def fmt_int(n):
    return f"{n:,}"


def md_cell(value):
    # Neutralize the two characters that break a GFM table rendered
    # inside a backtick code span: pipe (column separator) and backtick
    # (closes the code span). Backslash escapes are NOT processed
    # inside code spans, so substitution is the only safe option.
    # Bucket and file names in this codebase are kernel paths or
    # angle-bracketed sentinels and never contain either; replacing
    # rather than escaping keeps the rendered cell readable even if a
    # future PR introduces a hostile filename.
    s = str(value)
    return s.replace("|", "│").replace("`", "'")


def render(rollup_path, rows, total, budget_rows, top_n):
    top = rows[:top_n]
    lines = [
        "<!-- subsystem-rollup-comment -->",
        "## Subsystem Rollup",
        "",
    ]
    if total is not None:
        lines.append(f"Resident `.text`: **{fmt_int(total)} bytes**")
        lines.append("")

    lines.extend([
        f"Top {len(top)} buckets by resident `.text`:",
        "",
        "| bucket | bytes | % | symbols | icf | lto clones |",
        "| --- | ---: | ---: | ---: | ---: | ---: |",
    ])
    for row in top:
        lines.append(
            f"| `{md_cell(row['bucket'])}` | {fmt_int(row['bytes'])} | "
            f"{row['percent']:.2f} | {row['symbols']} | "
            f"{row['icf']} | {row['clones']} |"
        )

    if budget_rows:
        breached = [r for r in budget_rows if r["status"] != "ok"]
        lines.extend([
            "",
            f"Budget gate: **{'BREACH' if breached else 'ok'}**",
            "",
            "| bucket | actual | limit | band % | delta | status |",
            "| --- | ---: | ---: | ---: | ---: | --- |",
        ])
        for row in budget_rows:
            lines.append(
                f"| `{md_cell(row['bucket'])}` | {row['actual']} | "
                f"{row['limit']} | {row['band']} | {row['delta']} | "
                f"{row['status']} |"
            )

    lines.extend([
        "",
        f"_Source: `{rollup_path}`_",
        "",
    ])
    return "\n".join(lines)


def main(argv):
    ap = argparse.ArgumentParser(
        description="Render subsystem-rollup.txt as PR-friendly markdown."
    )
    ap.add_argument("--rollup", required=True, type=pathlib.Path)
    ap.add_argument("--budget-status", type=pathlib.Path)
    ap.add_argument("--top", type=int, default=12)
    ap.add_argument("--output", required=True, type=pathlib.Path)
    args = ap.parse_args(argv)

    if not args.rollup.exists():
        print(f"rollup-to-markdown: missing rollup: {args.rollup}", file=sys.stderr)
        return 1

    total, rows = read_rollup(args.rollup)
    budget_rows = read_budget_status(args.budget_status)
    body = render(args.rollup, rows, total, budget_rows, args.top)
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(body)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
