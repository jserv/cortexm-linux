#!/usr/bin/env python3

import argparse
import collections
import os
import pathlib
import re
import shutil
import subprocess
import sys


TOP_SYMBOL_RE = re.compile(r"^\s*(\d+)\s+(\S+)$")

HOTSPOT_RULES = [
    (
        "initramfs-gzip",
        {"inflate_fast", "zlib_inflate", "zlib_inflate_table", "gunzip"},
        "Initramfs decompression is hot. Keep one decompressor and disable unused RD_* codecs.",
    ),
    (
        "fdt",
        {"fdt_next_tag", "fdt_offset_ptr", "fdt_get_string", "__of_find_property", "of_find_property", "parse_prop_cells"},
        "Device-tree parsing is hot. Revisit DT size and disable unused platform/device drivers selected from defconfig.",
    ),
    (
        "mem-init",
        {"pfn_valid", "init_unavailable_range", "__init_single_page", "memmap_init_range", "overlap_memmap_init"},
        "Early memory setup is hot. Prioritize pruning subsystems that enlarge memblock/page allocator work.",
    ),
    (
        "console",
        {"mps2_early_putchar", "uart_console_write", "mps2_uart_console_putchar", "vsnprintf"},
        "Console output is a noticeable boot cost. Keep printk noise and dynamic-debug style features minimized.",
    ),
    (
        "path-lookup",
        {"link_path_walk", "do_mmap", "dput", "__d_alloc"},
        "VFS path lookup shows up in boot. Review procfs/debugfs/sysfs exposure and early userspace command count.",
    ),
]

SUBSYSTEM_RULES = [
    {
        "config": "CONFIG_IO_URING",
        "label": "io_uring",
        "match": re.compile(r"(io_uring|io_wq|uring_|msg_ring|sqpoll|uring_cmd|kbuf)"),
        "runtime": re.compile(r"(io_uring|io_wq|uring_|msg_ring|sqpoll|uring_cmd|kbuf)"),
        "ignore": re.compile(r"(?:^|_)(?:init|initcall|register|unregister|setup|probe)(?:_|$)", re.IGNORECASE),
        "min_bytes": 16384,
        "max_runtime_hits": 0,
        "max_symbol_hits": 0,
        "note": "io_uring code is built, but the workload only touches init paths and never exercises io_uring operations; disable CONFIG_IO_URING.",
    },
    {
        "config": "CONFIG_REGMAP",
        "label": "regmap",
        "match": re.compile(r"regmap", re.IGNORECASE),
        "runtime": re.compile(r"regmap", re.IGNORECASE),
        "ignore": re.compile(r"(?:^|_)(?:init|initcall|register|unregister|setup|probe|debugfs)(?:_|$)", re.IGNORECASE),
        "min_bytes": 4096,
        "max_runtime_hits": 256,
        "max_symbol_hits": 32,
        "note": "regmap helpers are built, but the workload only reaches probe/registration paths; disable CONFIG_REGMAP if no required device depends on it.",
    },
    {
        "config": "CONFIG_WATCHDOG",
        "label": "watchdog",
        "match": re.compile(r"(watchdog|wdt)", re.IGNORECASE),
        "runtime": re.compile(r"(watchdog|wdt)", re.IGNORECASE),
        "ignore": re.compile(r"(?:^|_)(?:init|initcall|register|unregister|setup|probe)(?:_|$)", re.IGNORECASE),
        "min_bytes": 4096,
        "max_runtime_hits": 64,
        "max_symbol_hits": 8,
        "note": "watchdog framework code is built, but the workload only reaches init/probe paths; disable CONFIG_WATCHDOG if hardware supervision is unnecessary.",
    },
]


def parse_kv_file(path: pathlib.Path):
    data = {}
    for line in path.read_text(encoding="utf-8", errors="replace").splitlines():
        if "=" not in line:
            continue
        key, value = line.split("=", 1)
        data[key] = value
    return data


def parse_config(config_path: pathlib.Path):
    config = {}
    for line in config_path.read_text(encoding="utf-8", errors="replace").splitlines():
        if line.startswith("CONFIG_") and "=" in line:
            key, value = line.split("=", 1)
            config[key] = value
        elif line.startswith("# CONFIG_") and line.endswith(" is not set"):
            key = line[2:].split(" ", 1)[0]
            config[key] = "n"
    return config


def parse_summary(summary_path: pathlib.Path):
    metadata = parse_kv_file(summary_path)
    top_symbols = []
    in_top = False
    for line in summary_path.read_text(encoding="utf-8", errors="replace").splitlines():
        if line == "top_symbols:":
            in_top = True
            continue
        if not in_top:
            continue
        match = TOP_SYMBOL_RE.match(line)
        if not match:
            continue
        top_symbols.append((int(match.group(1)), match.group(2)))
    return metadata, top_symbols


def load_text_symbols(vmlinux_path: pathlib.Path):
    nm = resolve_nm(vmlinux_path)
    proc = subprocess.run(
        [nm, "-S", "--size-sort", "--defined-only", str(vmlinux_path)],
        check=True,
        text=True,
        capture_output=True,
    )
    symbols = []
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
        symbols.append((name, size))
    return symbols


def load_hit_counts(hit_path: pathlib.Path):
    counts = {}
    for line in hit_path.read_text(encoding="utf-8", errors="replace").splitlines():
        fields = line.split(None, 1)
        if len(fields) != 2:
            continue
        counts[fields[1]] = int(fields[0])
    return counts


def resolve_nm(vmlinux_path: pathlib.Path):
    cross_compile = os.environ.get("CROSS_COMPILE", "")
    candidates = []
    if cross_compile:
        candidates.append(cross_compile + "nm")
    candidates.append("arm-uclinuxfdpiceabi-nm")

    repo_root = vmlinux_path.resolve().parent.parent
    candidates.append(str(repo_root / "toolchain" / "bin" / "arm-uclinuxfdpiceabi-nm"))

    for candidate in candidates:
        resolved = shutil.which(candidate) if not pathlib.Path(candidate).is_absolute() else candidate
        if resolved and pathlib.Path(resolved).exists():
            return resolved

    raise FileNotFoundError(
        "unable to locate arm-uclinuxfdpiceabi-nm; set CROSS_COMPILE or build the toolchain first"
    )


def is_runtime_symbol(name, runtime_pattern, ignore_pattern):
    if not runtime_pattern.search(name):
        return False
    if ignore_pattern and ignore_pattern.search(name):
        return False
    return True


def want_gzip_only(top_symbols):
    names = {name for _, name in top_symbols}
    gzip_markers = {"inflate_fast", "zlib_inflate", "zlib_inflate_table", "gunzip"}
    xz_markers = {"xz_dec_run", "xz_dec_lzma2_run"}
    lz4_markers = {"LZ4_decompress_safe", "LZ4_wildCopy32"}
    zstd_markers = {"ZSTD_decompress", "ZSTD_decompressSequences_body"}
    return bool(names & gzip_markers) and not bool(names & (xz_markers | lz4_markers | zstd_markers))


def infer_hotspot_categories(top_symbols):
    names = {name for _, name in top_symbols[:40]}
    categories = []
    for category, markers, note in HOTSPOT_RULES:
        matched = sorted(names & markers)
        if matched:
            categories.append((category, matched, note))
    return categories


def generate_fragment(config, top_symbols):
    lines = []
    notes = []

    lines.append("CONFIG_CC_OPTIMIZE_FOR_SIZE=y")

    if want_gzip_only(top_symbols):
        notes.append("Trace is dominated by zlib/gzip initramfs work; keep gzip and disable alternate initrd decompressors.")
        lines.extend(
            [
                "CONFIG_RD_GZIP=y",
                "# CONFIG_RD_BZIP2 is not set",
                "# CONFIG_RD_LZMA is not set",
                "# CONFIG_RD_XZ is not set",
                "# CONFIG_RD_LZO is not set",
                "# CONFIG_RD_LZ4 is not set",
                "# CONFIG_RD_ZSTD is not set",
            ]
        )

    if config.get("CONFIG_KERNEL_GZIP") not in {"y", "n"}:
        return lines, notes

    if config.get("CONFIG_KERNEL_GZIP") != "y":
        notes.append("Kernel image path already uses gzip in the boot flow; pin CONFIG_KERNEL_GZIP for repeatable PGO comparisons.")
        lines.extend(
            [
                "CONFIG_KERNEL_GZIP=y",
                "# CONFIG_KERNEL_LZ4 is not set",
                "# CONFIG_KERNEL_LZMA is not set",
                "# CONFIG_KERNEL_LZO is not set",
                "# CONFIG_KERNEL_XZ is not set",
                "# CONFIG_KERNEL_ZSTD is not set",
            ]
        )

    return lines, notes


def infer_unused_subsystems(config, symbols, hit_counts):
    findings = []
    for rule in SUBSYSTEM_RULES:
        config_name = rule["config"]
        if config.get(config_name) != "y":
            continue
        matched = [(name, size) for name, size in symbols if rule["match"].search(name)]
        if not matched:
            continue
        total_bytes = sum(size for _, size in matched)
        runtime_hits = 0
        init_hits = 0
        max_runtime_symbol_hits = 0
        runtime_samples = []
        init_samples = []
        for name, size in matched:
            hits = hit_counts.get(name, 0)
            if hits == 0:
                continue
            if is_runtime_symbol(name, rule["runtime"], rule["ignore"]):
                runtime_hits += hits
                max_runtime_symbol_hits = max(max_runtime_symbol_hits, hits)
                runtime_samples.append(name)
            else:
                init_hits += hits
                init_samples.append(name)
        max_runtime_hits = rule.get("max_runtime_hits", 0)
        max_symbol_hits = rule.get("max_symbol_hits", 0)
        if runtime_hits <= max_runtime_hits and max_runtime_symbol_hits <= max_symbol_hits and total_bytes >= rule["min_bytes"]:
            findings.append(
                {
                    "config": config_name,
                    "label": rule["label"],
                    "bytes": total_bytes,
                    "count": len(matched),
                    "note": rule["note"],
                    "init_hits": init_hits,
                    "runtime_hits": runtime_hits,
                    "max_runtime_symbol_hits": max_runtime_symbol_hits,
                    "samples": [name for name, _ in sorted(matched, key=lambda item: item[1], reverse=True)[:12]],
                    "runtime_samples": runtime_samples[:12],
                    "init_samples": init_samples[:12],
                }
            )
    return findings


def write_recommendations(output_dir: pathlib.Path, metadata, manifest, top_symbols, notes, categories, unused_subsystems):
    lines = []
    lines.append("Profile-guided kernel recommendations")
    lines.append("")
    lines.append(f"- Profile source: {metadata.get('profile_source', 'unknown')}")
    lines.append(f"- QEMU machine: {manifest.get('machine', 'unknown')}")
    lines.append(f"- QEMU cpu: {manifest.get('cpu', 'unknown')}")
    lines.append(f"- Workload file: {manifest.get('workload_file', 'unknown')}")
    lines.append(f"- Matched kernel trace ratio: {metadata.get('matched_ratio', 'unknown')}")
    if notes:
        for note in notes:
            lines.append(f"- {note}")
    if categories:
        for category, matched, note in categories:
            lines.append(f"- [{category}] {note} Hot symbols: {', '.join(matched)}")
    if unused_subsystems:
        for item in unused_subsystems:
            lines.append(
                f"- [unused:{item['label']}] {item['note']} "
                f"Estimated unhit text footprint: {item['bytes']} bytes. "
                f"Runtime hits: {item['runtime_hits']}. "
                f"Peak runtime symbol hits: {item['max_runtime_symbol_hits']}. "
                f"Init-only hits: {item['init_hits']}. "
                f"Samples: {', '.join(item['samples'][:5])}"
            )
    if not notes and not categories:
        lines.append("- No safe automatic config deltas were inferred from the current trace.")
    lines.append("")
    lines.append("Top hot symbols")
    for count, name in top_symbols[:20]:
        lines.append(f"- {name}: {count}")

    (output_dir / "recommendations.txt").write_text("\n".join(lines) + "\n", encoding="utf-8")


def write_hotspots(output_dir: pathlib.Path, top_symbols, categories):
    category_map = collections.defaultdict(list)
    for category, matched, _ in categories:
        for symbol in matched:
            category_map[category].append(symbol)

    lines = ["category symbol samples", ""]
    for category, symbols in sorted(category_map.items()):
        lines.append(f"{category}: {', '.join(symbols)}")
    lines.append("")
    lines.append("top_symbols:")
    for count, name in top_symbols[:40]:
        lines.append(f"{count:8d} {name}")

    (output_dir / "hotspots.txt").write_text("\n".join(lines) + "\n", encoding="utf-8")


def write_unused_symbols(output_dir: pathlib.Path, symbols, hit_counts):
    unseen = [(size, name) for name, size in symbols if hit_counts.get(name, 0) == 0]
    unseen.sort(reverse=True)

    lines = ["largest unseen text symbols", ""]
    for size, name in unseen[:120]:
        lines.append(f"{size:8d} {name}")
    (output_dir / "unused-symbols.txt").write_text("\n".join(lines) + "\n", encoding="utf-8")


def write_unused_subsystems(output_dir: pathlib.Path, unused_subsystems):
    lines = ["config label estimated_unhit_text_bytes symbol_count runtime_hits peak_runtime_symbol_hits init_only_hits samples", ""]
    for item in unused_subsystems:
        lines.append(
            f"{item['config']} {item['label']} {item['bytes']} {item['count']} "
            f"{item['runtime_hits']} {item['max_runtime_symbol_hits']} {item['init_hits']} "
            f"{', '.join(item['samples'][:8])}"
        )
    (output_dir / "unused-subsystems.txt").write_text("\n".join(lines) + "\n", encoding="utf-8")


def write_workload_notes(output_dir: pathlib.Path, manifest):
    lines = []
    lines.append("PGO workload definition")
    lines.append("")
    lines.append(f"source: {manifest.get('workload_file', 'unknown')}")
    lines.append(f"sha256: {manifest.get('workload_sha256', 'unknown')}")
    lines.append(f"guest_steps: {manifest.get('guest_steps', 'unknown')}")
    (output_dir / "workload.txt").write_text("\n".join(lines) + "\n", encoding="utf-8")


def main():
    parser = argparse.ArgumentParser(description="Generate kernel PGO config fragment and recommendations.")
    parser.add_argument("--profile-prefix", required=True, type=pathlib.Path)
    parser.add_argument("--linux-dir", required=True, type=pathlib.Path)
    parser.add_argument("--output-dir", required=True, type=pathlib.Path)
    args = parser.parse_args()

    summary_path = args.profile_prefix.with_name(args.profile_prefix.name + "_summary.txt")
    hit_path = args.profile_prefix.with_name(args.profile_prefix.name + "_hits.txt")
    manifest_path = args.profile_prefix.parent / "qemu-profile-manifest.txt"
    config_path = args.linux_dir / ".config"
    vmlinux_path = args.linux_dir / "vmlinux"
    if not summary_path.is_file():
        print(f"missing summary file: {summary_path}", file=sys.stderr)
        return 1
    if not manifest_path.is_file():
        print(f"missing QEMU manifest: {manifest_path}", file=sys.stderr)
        return 1
    if not hit_path.is_file():
        print(f"missing hit file: {hit_path}", file=sys.stderr)
        return 1
    if not config_path.is_file():
        print(f"missing kernel config: {config_path}", file=sys.stderr)
        return 1
    if not vmlinux_path.is_file():
        print(f"missing vmlinux image: {vmlinux_path}", file=sys.stderr)
        return 1

    args.output_dir.mkdir(parents=True, exist_ok=True)
    config = parse_config(config_path)
    metadata, top_symbols = parse_summary(summary_path)
    manifest = parse_kv_file(manifest_path)
    symbols = load_text_symbols(vmlinux_path)
    hit_counts = load_hit_counts(hit_path)
    fragment_lines, notes = generate_fragment(config, top_symbols)
    categories = infer_hotspot_categories(top_symbols)
    unused_subsystems = infer_unused_subsystems(config, symbols, hit_counts)

    # Unused subsystems are recommendations only -- do not auto-disable.
    # A short boot workload cannot prove a subsystem is safe to remove;
    # error handlers, hardware recovery, and non-boot paths are invisible.
    for item in unused_subsystems:
        fragment_lines.append(f"# RECOMMENDATION: {item['config']} was built but not hit by the workload")
        fragment_lines.append(f"# {item['note']}")
        fragment_lines.append(f"# Review manually before disabling: {item['config']}")

    fragment_path = args.output_dir / "pgo-kernel.config"
    fragment_path.write_text("\n".join(fragment_lines) + "\n", encoding="utf-8")
    write_recommendations(args.output_dir, metadata, manifest, top_symbols, notes, categories, unused_subsystems)
    write_hotspots(args.output_dir, top_symbols, categories)
    write_workload_notes(args.output_dir, manifest)
    write_unused_symbols(args.output_dir, symbols, hit_counts)
    write_unused_subsystems(args.output_dir, unused_subsystems)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
