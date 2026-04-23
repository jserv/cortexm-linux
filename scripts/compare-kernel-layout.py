#!/usr/bin/env python3

import argparse
import pathlib
import shutil
import subprocess
import os


BUCKETS = (16, 32, 64, 128)
HIT_COVERAGE_TARGETS = (0.50, 0.80)


def resolve_nm(vmlinux_path: pathlib.Path):
    cross_compile = os.environ.get("CROSS_COMPILE", "")
    candidates = []
    if cross_compile:
        candidates.append(cross_compile + "nm")
    candidates.append("arm-uclinuxfdpiceabi-nm")

    script_root = pathlib.Path(__file__).resolve().parent.parent
    candidates.append(str(script_root / "toolchain" / "bin" / "arm-uclinuxfdpiceabi-nm"))

    for candidate in candidates:
        resolved = shutil.which(candidate) if not pathlib.Path(candidate).is_absolute() else candidate
        if resolved and pathlib.Path(resolved).exists():
            return resolved

    raise FileNotFoundError(
        "unable to locate arm-uclinuxfdpiceabi-nm; set CROSS_COMPILE or build the toolchain first"
    )


def load_symbols(vmlinux_path: pathlib.Path):
    nm = resolve_nm(vmlinux_path)
    proc = subprocess.run(
        [nm, "-n", "-S", "--defined-only", str(vmlinux_path)],
        check=True,
        text=True,
        capture_output=True,
    )
    ordered = []
    by_name = {}
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
        record = {
            "addr": start,
            "end": start + size,
            "size": size,
            "name": name,
            "rank": len(ordered) + 1,
        }
        ordered.append(record)
        by_name[name] = record
    return ordered, by_name


def load_hits(hit_path: pathlib.Path):
    hits = []
    for line in hit_path.read_text(encoding="utf-8", errors="replace").splitlines():
        fields = line.split(None, 1)
        if len(fields) != 2:
            continue
        hits.append((fields[1], int(fields[0])))
    return hits


def load_order(order_path: pathlib.Path):
    names = []
    for line in order_path.read_text(encoding="utf-8", errors="replace").splitlines():
        stripped = line.strip()
        if not stripped or stripped.startswith("#"):
            continue
        names.append(stripped)
    return names


def select_symbols_by_bucket(hits, count):
    return [name for name, _ in hits[:count]]


def select_symbols_by_coverage(hits, coverage):
    total = sum(count for _, count in hits)
    if total == 0:
        return []
    running = 0
    selected = []
    for name, count in hits:
        selected.append(name)
        running += count
        if running / total >= coverage:
            break
    return selected


def compute_span(names, symbol_map):
    available = [symbol_map[name] for name in names if name in symbol_map]
    if not available:
        return None, 0
    start = min(item["addr"] for item in available)
    end = max(item["end"] for item in available)
    return end - start, len(available)


def compute_order_score(order_names, symbol_map):
    score = 0
    matched = 0
    for target_rank, name in enumerate(order_names, start=1):
        symbol = symbol_map.get(name)
        if symbol is None:
            continue
        matched += 1
        score += abs(symbol["rank"] - target_rank)
    return score, matched


def write_layout_summary(output_dir, baseline_map, candidate_map, hits, order_names):
    lines = ["Trace-driven kernel layout comparison", ""]

    for bucket in BUCKETS:
        names = select_symbols_by_bucket(hits, bucket)
        baseline_span, baseline_count = compute_span(names, baseline_map)
        candidate_span, candidate_count = compute_span(names, candidate_map)
        if baseline_span is None or candidate_span is None:
            continue
        delta = candidate_span - baseline_span
        lines.append(
            f"top_{bucket}_symbols span_bytes baseline={baseline_span} candidate={candidate_span} "
            f"delta={delta} matched={baseline_count}/{candidate_count}"
        )

    for coverage in HIT_COVERAGE_TARGETS:
        names = select_symbols_by_coverage(hits, coverage)
        baseline_span, baseline_count = compute_span(names, baseline_map)
        candidate_span, candidate_count = compute_span(names, candidate_map)
        if baseline_span is None or candidate_span is None:
            continue
        label = int(coverage * 100)
        delta = candidate_span - baseline_span
        lines.append(
            f"hit_coverage_{label}pct span_bytes baseline={baseline_span} candidate={candidate_span} "
            f"delta={delta} matched={baseline_count}/{candidate_count}"
        )

    baseline_score, baseline_matched = compute_order_score(order_names[:128], baseline_map)
    candidate_score, candidate_matched = compute_order_score(order_names[:128], candidate_map)
    lines.append(
        f"order_score_top128 baseline={baseline_score} candidate={candidate_score} "
        f"matched={baseline_matched}/{candidate_matched}"
    )

    (output_dir / "layout-comparison.txt").write_text("\n".join(lines) + "\n", encoding="utf-8")


def write_hot_symbol_table(output_dir, baseline_map, candidate_map, hits, order_names):
    order_rank = {name: idx + 1 for idx, name in enumerate(order_names)}
    lines = [
        "hot_rank hits order_rank name baseline_addr baseline_rank candidate_addr candidate_rank candidate_minus_baseline_rank",
        "",
    ]

    for hot_rank, (name, hit_count) in enumerate(hits[:128], start=1):
        baseline = baseline_map.get(name)
        candidate = candidate_map.get(name)
        if baseline is None and candidate is None:
            continue
        baseline_addr = f"0x{baseline['addr']:08x}" if baseline else "-"
        baseline_rank = str(baseline["rank"]) if baseline else "-"
        candidate_addr = f"0x{candidate['addr']:08x}" if candidate else "-"
        candidate_rank = str(candidate["rank"]) if candidate else "-"
        rank_delta = "-"
        if baseline and candidate:
            rank_delta = str(candidate["rank"] - baseline["rank"])
        lines.append(
            f"{hot_rank} {hit_count} {order_rank.get(name, '-')} {name} "
            f"{baseline_addr} {baseline_rank} {candidate_addr} {candidate_rank} {rank_delta}"
        )

    (output_dir / "layout-hot-symbols.txt").write_text("\n".join(lines) + "\n", encoding="utf-8")


def main():
    parser = argparse.ArgumentParser(description="Compare baseline and trace-ordered kernel layout.")
    parser.add_argument("--baseline-vmlinux", required=True, type=pathlib.Path)
    parser.add_argument("--candidate-vmlinux", required=True, type=pathlib.Path)
    parser.add_argument("--hits", required=True, type=pathlib.Path)
    parser.add_argument("--order-file", required=True, type=pathlib.Path)
    parser.add_argument("--output-dir", required=True, type=pathlib.Path)
    args = parser.parse_args()

    args.output_dir.mkdir(parents=True, exist_ok=True)
    _, baseline_map = load_symbols(args.baseline_vmlinux)
    _, candidate_map = load_symbols(args.candidate_vmlinux)
    hits = load_hits(args.hits)
    order_names = load_order(args.order_file)

    write_layout_summary(args.output_dir, baseline_map, candidate_map, hits, order_names)
    write_hot_symbol_table(args.output_dir, baseline_map, candidate_map, hits, order_names)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
