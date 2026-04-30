#!/usr/bin/env python3

# Diff vmlinux .text subsystem rollup against per-bucket byte budgets.
#
# The total-bytes regression gate is the coarse safeguard: it catches
# the image getting bigger overall. It cannot tell a 3% drop in
# drivers/ from a 3% growth in mm/ that cancels out. This script reads
# scripts/subsystem-rollup.py's table and compares each bucket against
# configs/subsystem-budget.txt with a per-bucket noise band -- LTO
# re-decides what to inline between rebuilds, so identical sources
# still produce small per-bucket fluctuations. Default band is +/- 2%;
# tighten after observing run-to-run variance over a week of clean
# builds.
#
# Exit codes:
#   0 -- all buckets within band, OR no budget rules active
#   1 -- one or more buckets exceed (limit * (1 + band/100))
#   2 -- missing/unreadable inputs (rollup or budget file)

import argparse
import pathlib
import sys

DEFAULT_BAND_PCT = 2.0


def read_budget(path):
    rules = {}
    for raw in path.read_text().splitlines():
        line = raw.split("#", 1)[0].strip()
        if not line:
            continue
        parts = line.split()
        if len(parts) < 2:
            print(
                f"check-subsystem-budget: ignoring malformed rule "
                f"in {path}: {raw!r}",
                file=sys.stderr,
            )
            continue
        bucket = parts[0]
        try:
            limit = int(parts[1])
        except ValueError:
            print(
                f"check-subsystem-budget: non-integer limit in {path}: "
                f"{raw!r}",
                file=sys.stderr,
            )
            continue
        try:
            band = float(parts[2]) if len(parts) >= 3 else DEFAULT_BAND_PCT
        except ValueError:
            band = DEFAULT_BAND_PCT
        rules[bucket] = (limit, band)
    return rules


def read_rollup(path):
    rows = {}
    for raw in path.read_text().splitlines():
        if not raw or raw.startswith("#"):
            continue
        # Tab-delimited. Bucket names contain dashes and angle brackets,
        # so split only on tab; leading whitespace is reserved for header
        # commentary that the # filter above already drops.
        parts = raw.split("\t")
        if len(parts) < 2:
            continue
        bucket = parts[0]
        try:
            rows[bucket] = int(parts[1])
        except ValueError:
            continue
    return rows


def main(argv):
    ap = argparse.ArgumentParser(
        description="Compare subsystem rollup against per-bucket budgets."
    )
    ap.add_argument("--rollup", required=True, type=pathlib.Path)
    ap.add_argument("--budget", required=True, type=pathlib.Path)
    ap.add_argument(
        "--output",
        required=True,
        type=pathlib.Path,
        help="Where to write the human-readable status table.",
    )
    args = ap.parse_args(argv)

    if not args.rollup.exists():
        print(
            f"check-subsystem-budget: rollup not found: {args.rollup}",
            file=sys.stderr,
        )
        return 2
    if not args.budget.exists():
        print(
            f"check-subsystem-budget: budget not found: {args.budget}",
            file=sys.stderr,
        )
        return 2

    budgets = read_budget(args.budget)
    rollup = read_rollup(args.rollup)

    if not budgets:
        # Empty file is a deliberate state: the operator has staged the
        # gate but not pinned ceilings yet (typical after the first
        # diagnostic build). Emit a status note and succeed.
        args.output.parent.mkdir(parents=True, exist_ok=True)
        args.output.write_text(
            "# subsystem budget check\n"
            "# no active rules in budget file -- nothing to gate\n"
        )
        return 0

    breaches = []
    lines = [
        f"# subsystem budget check (default band = +/- {DEFAULT_BAND_PCT}%)",
        f"# rollup: {args.rollup}",
        f"# budget: {args.budget}",
        "# bucket\tactual\tlimit\tband_pct\tdelta_vs_limit\tstatus",
    ]
    for bucket, (limit, band) in sorted(budgets.items()):
        actual = rollup.get(bucket, 0)
        delta = actual - limit
        ceiling = int(limit * (1 + band / 100.0))
        status = "BREACH" if actual > ceiling else "ok"
        if status == "BREACH":
            breaches.append((bucket, actual, limit, band, delta))
        lines.append(
            f"{bucket}\t{actual}\t{limit}\t{band:.1f}\t{delta:+d}\t{status}"
        )

    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text("\n".join(lines) + "\n")

    if breaches:
        print(
            f"check-subsystem-budget: {len(breaches)} bucket(s) breach "
            "the budget (after noise band):",
            file=sys.stderr,
        )
        for bucket, actual, limit, band, delta in breaches:
            print(
                f"  {bucket}: {actual} > {limit} "
                f"({delta:+d} bytes, band {band:.1f}%)",
                file=sys.stderr,
            )
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
