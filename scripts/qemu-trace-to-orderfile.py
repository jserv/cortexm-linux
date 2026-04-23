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
R07_RE = re.compile(r"\bR07=([0-9a-fA-F]+)\b")

CONCENTRATION_BUCKETS = (8, 16, 32, 64, 128)
MAX_ARM_SYSCALL = 511
ORDER_MIN_SYMBOLS = 64
ORDER_MAX_SYMBOLS = 256
ORDER_TARGET_HIT_RATIO = 0.80


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


def compute_concentration(counts):
    ordered = [count for _, count in counts.most_common()]
    total_hits = sum(ordered)
    metrics = {"total_kernel_symbol_hits": total_hits}

    for bucket in CONCENTRATION_BUCKETS:
        covered = sum(ordered[:bucket])
        metrics[f"top_{bucket}_hits"] = covered
        metrics[f"top_{bucket}_ratio"] = (covered / total_hits) if total_hits else 0.0

    recommended = (
        total_hits > 0
        and metrics["top_32_ratio"] >= 0.30
        and metrics["top_64_ratio"] >= 0.50
    )
    metrics["layout_ordering_recommended"] = recommended
    if recommended:
        metrics["layout_ordering_reason"] = "hot-path concentration clears the top-32/top-64 thresholds"
    else:
        metrics["layout_ordering_reason"] = (
            "trace is diffuse; top-32/top-64 symbol coverage is too low for reliable layout ordering"
        )
    return metrics


def select_ordered_names(counts, first_seen):
    ordered_items = sorted(
        counts.items(),
        key=lambda item: (-item[1], first_seen[item[0]], item[0]),
    )
    total_hits = sum(count for _, count in ordered_items)
    selected = []
    covered_hits = 0

    for name, count in ordered_items:
        if len(selected) >= ORDER_MAX_SYMBOLS:
            break
        if selected and len(selected) >= ORDER_MIN_SYMBOLS:
            if total_hits > 0 and (covered_hits / total_hits) >= ORDER_TARGET_HIT_RATIO:
                break
        selected.append(name)
        covered_hits += count

    if not selected:
        return [], 0.0
    if total_hits == 0:
        return selected, 0.0
    return selected, covered_hits / total_hits


def parse_trace(trace_path: pathlib.Path, starts, records):
    counts = collections.Counter()
    first_seen = {}
    matched = 0
    total = 0
    pending_tb = None
    syscall_counts = collections.Counter()
    syscall_sites = collections.defaultdict(list)

    with trace_path.open("r", encoding="utf-8", errors="replace") as handle:
        for raw_line in handle:
            line = raw_line.rstrip("\n")

            if "Trace" in line:
                match = TRACE_RE.search(line)
                if not match:
                    continue
                total += 1
                pc = int(match.group(1), 16) & ~1
                name = find_symbol(pc, starts, records)
                if name is not None:
                    matched += 1
                    counts[name] += 1
                    if name not in first_seen:
                        first_seen[name] = matched

                pending_tb = {"pc": pc, "symbol": name}
                continue

            if pending_tb is not None and "R07=" in line:
                match = R07_RE.search(line)
                if match and pending_tb["symbol"] == "vector_swi":
                    r7 = int(match.group(1), 16)
                    if r7 > MAX_ARM_SYSCALL:
                        pending_tb = None
                        continue
                    syscall_counts[r7] += 1
                    sites = syscall_sites[r7]
                    if len(sites) < 8:
                        sites.append((pending_tb["pc"], pending_tb["pc"], "vector_swi"))
                pending_tb = None

    return counts, first_seen, total, matched, syscall_counts, syscall_sites


def write_outputs(prefix: pathlib.Path, counts, first_seen, total, matched, syscall_counts, syscall_sites):
    ordered_names = [
        name
        for name, _ in sorted(
            counts.items(),
            key=lambda item: (-item[1], first_seen[item[0]], item[0]),
        )
    ]
    focus_names, focus_ratio = select_ordered_names(counts, first_seen)

    ld_profile = prefix.with_name(prefix.name + "_ld_profile.txt")
    with ld_profile.open("w", encoding="utf-8") as handle:
        handle.write("# Trace-derived hot-function order for vmlinux\n")
        handle.write(
            f"# selected_symbols={len(focus_names)} target_hit_ratio={ORDER_TARGET_HIT_RATIO:.2f} "
            f"covered_hit_ratio={focus_ratio:.4f}\n"
        )
        for name in focus_names:
            handle.write(f"{name}\n")

    ld_profile_full = prefix.with_name(prefix.name + "_ld_profile_full.txt")
    with ld_profile_full.open("w", encoding="utf-8") as handle:
        handle.write("# Full trace-ranked function order for vmlinux\n")
        for name in ordered_names:
            handle.write(f"{name}\n")

    hits = prefix.with_name(prefix.name + "_hits.txt")
    with hits.open("w", encoding="utf-8") as handle:
        for name, count in counts.most_common():
            handle.write(f"{count} {name}\n")

    concentration = compute_concentration(counts)
    concentration_path = prefix.with_name(prefix.name + "_concentration.txt")
    with concentration_path.open("w", encoding="utf-8") as handle:
        for key in ("total_kernel_symbol_hits",):
            handle.write(f"{key}={concentration[key]}\n")
        for bucket in CONCENTRATION_BUCKETS:
            handle.write(f"top_{bucket}_hits={concentration[f'top_{bucket}_hits']}\n")
            handle.write(f"top_{bucket}_ratio={concentration[f'top_{bucket}_ratio']:.4f}\n")
        handle.write(
            "layout_ordering_recommended="
            f"{'yes' if concentration['layout_ordering_recommended'] else 'no'}\n"
        )
        handle.write(f"layout_ordering_reason={concentration['layout_ordering_reason']}\n")

    summary = prefix.with_name(prefix.name + "_summary.txt")
    with summary.open("w", encoding="utf-8") as handle:
        handle.write("profile_source=qemu-system-arm-system-mode\n")
        has_r7 = len(syscall_counts) > 0
        handle.write(f"trace_selector={'exec,cpu,in_asm' if has_r7 else 'exec,in_asm'}\n")
        handle.write(f"trace_blocks={total}\n")
        handle.write(f"matched_kernel_blocks={matched}\n")
        handle.write(f"matched_ratio={(matched / total):.4f}\n" if total else "matched_ratio=0.0000\n")
        handle.write(f"ordering_symbol_count={len(focus_names)}\n")
        handle.write(f"ordering_hit_ratio={focus_ratio:.4f}\n")
        for bucket in CONCENTRATION_BUCKETS:
            handle.write(f"top_{bucket}_ratio={concentration[f'top_{bucket}_ratio']:.4f}\n")
        handle.write(
            "layout_ordering_recommended="
            f"{'yes' if concentration['layout_ordering_recommended'] else 'no'}\n"
        )
        handle.write(f"layout_ordering_reason={concentration['layout_ordering_reason']}\n")
        handle.write(f"detected_syscalls={len(syscall_counts)}\n")
        handle.write("top_symbols:\n")
        for name, count in counts.most_common(80):
            handle.write(f"{count:8d} {name}\n")

    syscalls_path = prefix.with_name(prefix.name + "_syscalls.txt")
    with syscalls_path.open("w", encoding="utf-8") as handle:
        handle.write("trace_mode=vector_swi_r7_samples\n")
        handle.write(f"max_syscall_number={MAX_ARM_SYSCALL}\n")
        handle.write(f"detected_syscalls={len(syscall_counts)}\n")
        handle.write("syscall_hits:\n")
        for number, count in sorted(syscall_counts.items(), key=lambda item: (-item[1], item[0])):
            site_summary = ",".join(
                f"0x{site_addr:08x}@0x{tb_pc:08x}/{tag}"
                for site_addr, tb_pc, tag in syscall_sites.get(number, [])
            )
            handle.write(f"{number} {count} {site_summary}\n")


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

    counts, first_seen, total, matched, syscall_counts, syscall_sites = parse_trace(
        args.trace, starts, records
    )
    if not counts:
        print("trace did not match any kernel text symbols", file=sys.stderr)
        return 1

    args.profile_prefix.parent.mkdir(parents=True, exist_ok=True)
    write_outputs(
        args.profile_prefix,
        counts,
        first_seen,
        total,
        matched,
        syscall_counts,
        syscall_sites,
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
