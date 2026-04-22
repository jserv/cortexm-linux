#!/usr/bin/env python3

import argparse
import bisect
import collections
import os
import pathlib
import re
import shutil
import subprocess
import sys


TRACE_RE = re.compile(r"Trace\s+\d+:\s+0x[0-9a-fA-F]+\s+\[[0-9a-fA-F]+/([0-9a-fA-F]+)/")


def resolve_nm(vmlinux: pathlib.Path):
    cross_compile = os.environ.get("CROSS_COMPILE", "")
    candidates = []
    if cross_compile:
        candidates.append(cross_compile + "nm")
    candidates.append("arm-uclinuxfdpiceabi-nm")

    repo_root = vmlinux.resolve().parent.parent
    candidates.append(str(repo_root / "toolchain" / "bin" / "arm-uclinuxfdpiceabi-nm"))

    for candidate in candidates:
        resolved = shutil.which(candidate) if not pathlib.Path(candidate).is_absolute() else candidate
        if resolved and pathlib.Path(resolved).exists():
            return resolved

    raise FileNotFoundError(
        "unable to locate arm-uclinuxfdpiceabi-nm; set CROSS_COMPILE or build the toolchain first"
    )


def load_symbols(vmlinux: pathlib.Path):
    nm = resolve_nm(vmlinux)
    cmd = [nm, "-n", "-S", "--defined-only", str(vmlinux)]
    proc = subprocess.run(cmd, check=True, text=True, capture_output=True)

    starts = []
    records = []
    for line in proc.stdout.splitlines():
        fields = line.split(None, 3)
        if len(fields) != 4:
            continue
        start_hex, size_hex, sym_type, name = fields
        if sym_type not in {"T", "t", "W", "w"}:
            continue
        size = int(size_hex, 16)
        if size == 0:
            continue
        # Mask Thumb LSB so symbol addresses align with masked PCs.
        start = int(start_hex, 16) & ~1
        starts.append(start)
        records.append((start, start + size, name))

    return starts, records


def find_symbol(pc: int, starts, records):
    idx = bisect.bisect_right(starts, pc) - 1
    if idx < 0:
        return None
    start, end, name = records[idx]
    if start <= pc < end:
        return name
    return None


def parse_trace(trace_path: pathlib.Path, starts, records):
    counts = collections.Counter()
    first_seen = {}
    matched = 0
    total = 0

    with trace_path.open("r", encoding="utf-8", errors="replace") as handle:
        for line in handle:
            if "Trace" not in line:
                continue
            match = TRACE_RE.search(line)
            if not match:
                continue
            total += 1
            pc = int(match.group(1), 16) & ~1
            name = find_symbol(pc, starts, records)
            if name is None:
                continue
            matched += 1
            counts[name] += 1
            if name not in first_seen:
                first_seen[name] = matched

    return counts, first_seen, total, matched


def write_outputs(prefix: pathlib.Path, counts, first_seen, total, matched):
    # Primary: frequency descending (hot functions first for cache locality).
    # Tiebreaker: first-seen order (preserves boot-time layout for equal counts).
    ordered_names = [
        name
        for name, _ in sorted(
            counts.items(),
            key=lambda item: (-item[1], first_seen[item[0]], item[0]),
        )
    ]

    ld_profile = prefix.with_name(prefix.name + "_ld_profile.txt")
    with ld_profile.open("w", encoding="utf-8") as handle:
        handle.write("# Trace-derived function order for vmlinux\n")
        for name in ordered_names:
            handle.write(f"{name}\n")

    hits = prefix.with_name(prefix.name + "_hits.txt")
    with hits.open("w", encoding="utf-8") as handle:
        for name, count in counts.most_common():
            handle.write(f"{count} {name}\n")

    summary = prefix.with_name(prefix.name + "_summary.txt")
    with summary.open("w", encoding="utf-8") as handle:
        handle.write("profile_source=qemu-system-arm-system-mode\n")
        handle.write(f"trace_blocks={total}\n")
        handle.write(f"matched_kernel_blocks={matched}\n")
        handle.write(f"matched_ratio={(matched / total):.4f}\n" if total else "matched_ratio=0.0000\n")
        handle.write("top_symbols:\n")
        for name, count in counts.most_common(80):
            handle.write(f"{count:8d} {name}\n")


def main():
    parser = argparse.ArgumentParser(
        description="Convert QEMU exec traces into an ld.lld symbol ordering file."
    )
    parser.add_argument("--trace", required=True, type=pathlib.Path)
    parser.add_argument("--vmlinux", required=True, type=pathlib.Path)
    parser.add_argument("--manifest", required=True, type=pathlib.Path)
    parser.add_argument("--profile-prefix", required=True, type=pathlib.Path)
    args = parser.parse_args()

    if not args.manifest.is_file():
        print(f"missing QEMU manifest: {args.manifest}", file=sys.stderr)
        return 1

    starts, records = load_symbols(args.vmlinux)
    if not records:
        print("no text symbols found in vmlinux", file=sys.stderr)
        return 1

    counts, first_seen, total, matched = parse_trace(args.trace, starts, records)
    if not counts:
        print("trace did not match any kernel text symbols", file=sys.stderr)
        return 1

    args.profile_prefix.parent.mkdir(parents=True, exist_ok=True)
    write_outputs(args.profile_prefix, counts, first_seen, total, matched)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
