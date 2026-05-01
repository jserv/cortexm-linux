#!/usr/bin/env python3

# LTO-aware vmlinux .text rollup by source subsystem.
#
# Maps every sized text symbol back to a top-level kernel directory
# (init/, kernel/, mm/, fs/, drivers/, net/, security/, ...). The five
# normalization rules below are the only way the rollup numbers are
# trustworthy under GCC LTO; without them the table silently double-
# counts ICF-merged code or miscredits constprop/isra clones.
#
#   1. GCC clone suffixes are stripped before bucket lookup but their
#      bytes still sum into the parent bucket. A `.constprop.0` clone
#      is a constant-specialized COPY of the function body, not an
#      alias; the bytes are real. Suffixes can stack
#      (foo.constprop.0.isra.0) so stripping iterates.
#   2. GCC IPA-ICF (ld.bfd has no --icf) preserves merged names as
#      aliases pointing at the same start address. nm-then-bucket would
#      double-count. We dedup by start address; multi-name groups land
#      in <icf-merged> because true pre-fold provenance is not
#      recoverable from the final vmlinux alone.
#   3. Cross-TU inlining: the surviving symbol's source attribution is
#      the caller's file, not the inlinee's. The rollup answers "where
#      the code lives in the image," not "where it was written."
#   4. Compiler section partitioning (.text.hot/.text.unlikely/...) is
#      metadata, not a bucket. Symbols inside still resolve normally.
#      Bytes the linker emitted that no nm symbol claims (alignment
#      padding, partition fragments without an owner) fall through to
#      <compiler-partition>.
#   5. addr2line -i emits the full inline stack per query. We use -p
#      mode and the "(inlined by) " continuation marker to delimit
#      stacks reliably, then pick the OUTERMOST frame for attribution
#      (matches "where the code lives" framing).
#
# Production builds run without DWARF (CONFIG_DEBUG_INFO_NONE=y).
# addr2line then resolves nothing and the rollup would degrade to
# ~99.7% <unknown>. This script fails with a non-zero exit when more
# than half of .text is unresolved, so the caller can skip the rollup
# rather than emit a misleading file. Diagnostic builds opt in via
# KERNEL_DEBUG_INFO=reduced (CONFIG_DEBUG_INFO_REDUCED=y).
#
# Outputs (written next to --output):
#   subsystem-rollup.txt        primary table consumed by the gate
#   subsystem-rollup-bars.svg   horizontal bars, sorted by bytes
#   subsystem-rollup-tree.html  D3 treemap, hover-to-drill
#   subsystem-rollup-deep.txt   per-bucket 2nd-level + top-file
#                               breakdown (only when --deep is set)
#   subsystem-rollup-deep.html  styled-table version of the deep
#                               breakdown (only when --deep is set)

import argparse
import collections
import json
import os
import pathlib
import posixpath
import re
import shutil
import subprocess
import sys
import xml.sax.saxutils

TEXT_TYPES = {"T", "t", "W", "w"}


def is_resident_text_section(section):
    # We want resident text only. Linux's vmlinux.lds.S typically
    # collapses per-function .text.<funcname> sections into a single
    # .text after --gc-sections, so the common case is exact ".text".
    # Allow .text.hot / .text.unlikely / .text.<funcname> in case the
    # linker keeps any per-bucket fragments separate. Reject
    # .init.text, .exit.text, .head.text, .ref.text -- those are not
    # part of resident .text and would inflate the rollup by ~7%.
    return section == ".text" or section.startswith(".text.")

TOP_LEVEL_DIRS = frozenset({
    "arch", "block", "certs", "crypto", "drivers", "fs", "init",
    "io_uring", "ipc", "kernel", "lib", "mm", "net", "rust", "samples",
    "scripts", "security", "sound", "tools", "usr", "virt",
})

# Subdirectories large enough to deserve a one-deeper bucket so a
# single driver family does not hide inside the parent.
SPLIT_ONE_DEEPER = frozenset({"arch", "drivers", "sound", "net"})

# Iterative strip set. Patterns must be anchored to end-of-name and may
# stack: GCC emits names like `foo.constprop.0.isra.0` after multiple
# IPA passes. The dot-suffix family is restricted -- do NOT generalize
# to "trim any trailing dot segment," GCC also produces legitimate
# non-clone dot-suffixes (e.g. `__cfi_*`).
CLONE_SUFFIX_RE = re.compile(
    r"\.(?:lto_priv|constprop|isra|part|cold|localalias)(?:\.\d+)?$"
)

# addr2line -p -f -i: first frame on its own line, outer frames each
# prefixed " (inlined by) ". We read until the next un-prefixed line
# to know the previous query's stack is complete.
INLINED_BY_PREFIX = " (inlined by) "

# "func at file:line" or "func at file:line (discriminator N)".
PRETTY_LINE_RE = re.compile(
    r"^(?P<func>.*?) at (?P<path>.*?):[0-9?]+"
    r"(?:\s+\(discriminator.*\))?$"
)

UNKNOWN_LOCATION = "??"
UNRESOLVED_FAIL_RATIO = 0.5


def resolve_tool(name, toolchain_bin):
    # Precedence: --toolchain-bin > CROSS_COMPILE > PATH. Stray
    # CROSS_COMPILE pointing at a different toolchain would otherwise
    # silently mismatch nm and addr2line and corrupt attribution.
    candidates = []
    if toolchain_bin is not None:
        candidates.append(str(toolchain_bin / ("arm-uclinuxfdpiceabi-" + name)))
    cross_compile = os.environ.get("CROSS_COMPILE", "")
    if cross_compile:
        candidates.append(cross_compile + name)
    candidates.append("arm-uclinuxfdpiceabi-" + name)

    for candidate in candidates:
        if pathlib.Path(candidate).is_absolute():
            resolved = candidate if pathlib.Path(candidate).exists() else None
        else:
            resolved = shutil.which(candidate)
        if resolved and pathlib.Path(resolved).exists():
            return resolved
    raise FileNotFoundError(f"unable to locate arm-uclinuxfdpiceabi-{name}")


def collect_text_symbols(nm, vmlinux):
    # `-f sysv` is the only nm format that exposes the ELF section per
    # symbol, which we need to exclude .init.text and friends. The
    # output is pipe-delimited:
    #   Name | Value | Class | Type | Size | Line | Section
    # Older nm emits a leading header and a blank line; both are
    # filtered by the field-count check below.
    cmd = [nm, "-n", "-f", "sysv", "--defined-only", str(vmlinux)]
    proc = subprocess.run(cmd, check=True, text=True, capture_output=True)
    rows = []
    for line in proc.stdout.splitlines():
        if "|" not in line:
            continue
        fields = [f.strip() for f in line.split("|")]
        if len(fields) < 7:
            continue
        name, value, klass, _type, size_str, _src_line, section = fields
        if len(klass) != 1 or klass not in TEXT_TYPES:
            continue
        if not is_resident_text_section(section):
            continue
        try:
            addr = int(value, 16)
            size = int(size_str, 16)
        except ValueError:
            continue
        if size == 0:
            continue
        # Thumb function symbols carry the low bit set; addr2line and
        # the linker want the even instruction address.
        rows.append((addr & ~1, size, name))
    return rows


def normalize_clone(name):
    canonical = name
    stripped = False
    while True:
        m = CLONE_SUFFIX_RE.search(canonical)
        if not m:
            return canonical, stripped
        canonical = canonical[: m.start()]
        stripped = True


def parse_pretty_line(line):
    m = PRETTY_LINE_RE.match(line)
    if not m:
        return None, None
    return m.group("func"), m.group("path")


def resolve_inline_stacks(addr2line, vmlinux, addresses):
    if not addresses:
        return []
    cmd = [addr2line, "-e", str(vmlinux), "-p", "-f", "-i"]
    payload = "\n".join(f"0x{a:x}" for a in addresses) + "\n"
    proc = subprocess.run(
        cmd, input=payload, check=True, text=True, capture_output=True
    )

    stacks = []
    current = None
    for raw in proc.stdout.splitlines():
        if raw.startswith(INLINED_BY_PREFIX):
            if current is None:
                # Continuation without a head: corrupt output. Drop
                # the line; the unresolved tally will surface it.
                continue
            current.append(parse_pretty_line(raw[len(INLINED_BY_PREFIX):]))
        else:
            if current is not None:
                stacks.append(current)
            current = [parse_pretty_line(raw)]
    if current is not None:
        stacks.append(current)
    if len(stacks) != len(addresses):
        raise RuntimeError(
            f"addr2line returned {len(stacks)} inline stacks for "
            f"{len(addresses)} addresses; pretty-print parser desynced"
        )
    return stacks


def normalize_path(path, tree_prefix):
    if path is None or path in ("", UNKNOWN_LOCATION):
        return None
    # Lex-normalize `.` / `..` segments before any further routing.
    # DWARF emits paths like `lib/../scripts/dtc/libfdt/fdt_ro.c` for
    # cross-tree includes (libfdt is built from `scripts/dtc/libfdt/`
    # but referenced relative to `lib/`). Without normpath, both
    # `bucket_for()` and the depth-2 splitter see `lib` as the head
    # and produce the meaningless key `lib/..`. posixpath.normpath
    # is filesystem-free; it will not follow symlinks or stat the
    # path, only collapse the segments.
    path = posixpath.normpath(path)
    if tree_prefix and (path == tree_prefix or path.startswith(tree_prefix + "/")):
        return path[len(tree_prefix):].lstrip("/")
    if path.startswith("/"):
        # Build path stayed absolute. Walk components for the first
        # known top-level kernel dir.
        parts = path.split("/")
        for idx, part in enumerate(parts):
            if part in TOP_LEVEL_DIRS:
                return "/".join(parts[idx:])
        return path  # external -- bucket_for() will route to <external>
    return path


def bucket_for(path):
    if path is None:
        return "<unknown>"
    if path.startswith("/"):
        return "<external>"
    parts = path.split("/")
    head = parts[0]
    if head not in TOP_LEVEL_DIRS:
        return head or "<unknown>"
    if head in SPLIT_ONE_DEEPER and len(parts) > 1:
        return f"{head}/{parts[1]}"
    return head


def attribute_outermost(stack, tree_prefix):
    # stack is innermost-first; the outermost frame ("where the code
    # lives in the image") is the last entry. Walk from the end so a
    # well-resolved outer frame wins over an unresolvable inner frame.
    for func, path in reversed(stack):
        normed = normalize_path(path, tree_prefix)
        if normed is not None:
            return bucket_for(normed), normed
    return "<unknown>", None


def text_section_total(size_tool, vmlinux):
    try:
        proc = subprocess.run(
            [size_tool, "-A", str(vmlinux)],
            check=True, text=True, capture_output=True,
        )
    except (FileNotFoundError, subprocess.CalledProcessError):
        return None
    total = 0
    for line in proc.stdout.splitlines():
        fields = line.split()
        if len(fields) < 2:
            continue
        if not is_resident_text_section(fields[0]):
            continue
        try:
            total += int(fields[1])
        except ValueError:
            continue
    return total or None


class BucketAgg:
    __slots__ = ("bytes", "symbols", "icf", "clones", "files", "icf_groups")

    def __init__(self):
        self.bytes = 0
        self.symbols = 0
        self.icf = 0
        self.clones = 0
        self.files = collections.defaultdict(
            lambda: {"bytes": 0, "symbols": 0}
        )
        self.icf_groups = []  # filled only for the <icf-merged> bucket


def build_deduped_entries(rows):
    # Group by start address. Multiple distinct names at the same
    # address after clone-suffix stripping is the IPA-ICF signature.
    by_addr = collections.defaultdict(list)
    for addr, size, name in rows:
        by_addr[addr].append((size, name))

    addrs = sorted(by_addr.keys())
    entries = []
    for i, addr in enumerate(addrs):
        items = by_addr[addr]
        names = sorted({n for _, n in items})
        canonicals = []
        any_clone = False
        for n in names:
            cn, was_clone = normalize_clone(n)
            canonicals.append(cn)
            any_clone = any_clone or was_clone
        is_icf = len({c for c in canonicals}) > 1
        # Symbols at the same address should all carry the same size,
        # but defend against weak/strong overlays by taking the max.
        size = max(s for s, _ in items)
        # Clamp by next address so ARM entry-point macros that emit
        # multiple T symbols with overlapping ends do not double-count.
        next_addr = addrs[i + 1] if i + 1 < len(addrs) else addr + size
        effective = min(size, max(0, next_addr - addr))
        if effective <= 0:
            continue
        entries.append({
            "addr": addr,
            "size": effective,
            "aliases": names,
            "is_icf": is_icf,
            "is_clone": any_clone,
        })
    return entries


def aggregate(entries, stacks, tree_prefix):
    buckets = collections.defaultdict(BucketAgg)
    total_bytes = 0
    for entry, stack in zip(entries, stacks):
        if entry["is_icf"]:
            # True pre-fold provenance is not reliably recoverable from
            # the final vmlinux. Bucket the bytes once under <icf-merged>
            # and stash the alias list for the treemap drill-down.
            bucket_name, normed = "<icf-merged>", None
        else:
            bucket_name, normed = attribute_outermost(stack, tree_prefix)

        b = buckets[bucket_name]
        b.bytes += entry["size"]
        b.symbols += 1
        if entry["is_icf"]:
            b.icf += 1
            b.icf_groups.append({
                "addr": entry["addr"],
                "size": entry["size"],
                "aliases": entry["aliases"],
            })
        if entry["is_clone"]:
            b.clones += 1

        file_key = normed if normed else "<unfiled>"
        b.files[file_key]["bytes"] += entry["size"]
        b.files[file_key]["symbols"] += 1
        total_bytes += entry["size"]
    return buckets, total_bytes


def write_table(buckets, grand_total, path):
    rows = sorted(buckets.items(), key=lambda kv: kv[1].bytes, reverse=True)
    lines = [
        "# subsystem-rollup -- vmlinux .text by source bucket",
        "# Attribution answers 'where the code lives in the final image,'",
        "# not 'where it was originally written.' Under -flto, leaf",
        "# functions are inlined into callers; the surviving address",
        "# belongs to the caller's file.",
        "# Special buckets: <icf-merged> (IPA-ICF folded, pre-fold",
        "# origin not recoverable), <compiler-partition> (linker-emitted",
        "# bytes outside any nm symbol), <unknown> (DWARF resolution",
        "# failed), <external> (path outside the kernel tree).",
        f"# total bytes: {grand_total}",
        "#",
        "# bucket\tbytes\tpercent\tsymbols\ticf_merged\tlto_clones",
    ]
    for name, b in rows:
        pct = (b.bytes * 100.0 / grand_total) if grand_total else 0.0
        lines.append(
            f"{name}\t{b.bytes}\t{pct:.2f}\t{b.symbols}"
            f"\t{b.icf}\t{b.clones}"
        )
    path.write_text("\n".join(lines) + "\n")


def _esc(s):
    # Escape both quote styles in addition to <>&. The current HTML
    # template uses _esc() only in tag content, but the same helper
    # is the obvious place a future caller would reach for when
    # filling an attribute value -- keep it safe in both contexts so
    # a future change does not silently introduce an XSS surface.
    return xml.sax.saxutils.escape(
        str(s), {'"': "&quot;", "'": "&apos;"}
    )


def write_svg(buckets, grand_total, path):
    rows = sorted(buckets.items(), key=lambda kv: kv[1].bytes, reverse=True)
    if not rows:
        path.write_text(
            '<svg xmlns="http://www.w3.org/2000/svg" width="10" height="10"/>\n'
        )
        return

    chart_w = 760
    label_w = 260
    text_w = 186
    bar_h = 24
    row_gap = 8
    pad_x = 22
    pad_y = 22
    title_h = 54
    height = pad_y * 2 + title_h + len(rows) * (bar_h + row_gap)
    width = label_w + chart_w + text_w
    max_bytes = max(b.bytes for _, b in rows) or 1

    parts = [
        '<?xml version="1.0" encoding="UTF-8"?>',
        f'<svg xmlns="http://www.w3.org/2000/svg" width="{width}" '
        f'height="{height}" font-family="Iosevka Term, SFMono-Regular, Menlo, monospace" '
        'font-size="13">',
        '<defs>',
        '<linearGradient id="bg" x1="0" y1="0" x2="1" y2="1">',
        '<stop offset="0%" stop-color="#f7f2e8"/>',
        '<stop offset="100%" stop-color="#fdfcf9"/>',
        '</linearGradient>',
        '<linearGradient id="barMain" x1="0" y1="0" x2="1" y2="0">',
        '<stop offset="0%" stop-color="#1f6f78"/>',
        '<stop offset="100%" stop-color="#2d9c8f"/>',
        '</linearGradient>',
        '<linearGradient id="barSpecial" x1="0" y1="0" x2="1" y2="0">',
        '<stop offset="0%" stop-color="#9f3a2c"/>',
        '<stop offset="100%" stop-color="#d46b4c"/>',
        '</linearGradient>',
        '</defs>',
        f'<rect width="{width}" height="{height}" fill="url(#bg)"/>',
        f'<text x="{pad_x}" y="{pad_y + 12}" fill="#17313a" '
        'font-size="18" font-weight="700">vmlinux .text by subsystem</text>',
        f'<text x="{pad_x}" y="{pad_y + 34}" fill="#52636a" '
        'font-size="12">Sorted by resident bytes; special buckets '
        'highlight compiler/linker artefacts.</text>',
        f'<line x1="{pad_x + label_w}" y1="{pad_y + title_h - 2}" '
        f'x2="{pad_x + label_w}" y2="{height - pad_y}" stroke="#d8d2c4"/>',
    ]
    for i, (name, b) in enumerate(rows):
        y = pad_y + title_h + i * (bar_h + row_gap)
        bar_w = max(1, int(chart_w * b.bytes / max_bytes))
        pct = (b.bytes * 100.0 / grand_total) if grand_total else 0.0
        color = "url(#barSpecial)" if name.startswith("<") else "url(#barMain)"
        rail_x = pad_x + label_w
        parts.append(
            f'<text x="{pad_x + label_w - 12}" y="{y + 16}" '
            f'text-anchor="end" fill="#24343a">{_esc(name)}</text>'
        )
        parts.append(
            f'<rect x="{rail_x}" y="{y}" width="{chart_w}" '
            f'height="{bar_h - 4}" rx="6" fill="#e8e1d5"/>'
        )
        parts.append(
            f'<rect x="{rail_x}" y="{y}" width="{bar_w}" '
            f'height="{bar_h - 4}" rx="6" fill="{color}"/>'
        )
        parts.append(
            f'<text x="{rail_x + bar_w + 10}" y="{y + 16}" '
            f'fill="#24343a">{b.bytes:,} bytes  {pct:.1f}%</text>'
        )
    parts.append("</svg>")
    path.write_text("\n".join(parts) + "\n")


TREEMAP_HTML = """<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8"/>
<title>vmlinux .text rollup -- subsystem breakdown</title>
<style>
:root {
  --bg: #f7f4ed;
  --panel: #fffdf9;
  --line: #ddd6c8;
  --ink: #1f2a30;
  --muted: #66757c;
  --accent: #236d72;
  --accent-soft: #58a8a0;
  --special: #a45137;
  --special-soft: #d17d5b;
}
* { box-sizing: border-box; }
body {
  margin: 0;
  font-family: "Avenir Next", "Segoe UI", "Helvetica Neue", sans-serif;
  background: var(--bg);
  color: var(--ink);
}
header {
  padding: 18px 22px 14px;
  border-bottom: 1px solid var(--line);
  background: var(--panel);
  position: sticky;
  top: 0;
  z-index: 5;
}
header h1 { margin: 0; font-size: 28px; letter-spacing: -0.02em; }
header p { margin: 8px 0 0; font-size: 13px; color: var(--muted); max-width: 980px; line-height: 1.45; }
header code {
  background: #f0ece3;
  padding: 2px 6px;
  border-radius: 6px;
  font-family: "Iosevka Term", "SFMono-Regular", monospace;
  font-size: 12px;
}
.summary {
  display: grid;
  grid-template-columns: repeat(4, minmax(0, 1fr));
  gap: 10px;
  margin-top: 14px;
}
.card {
  padding: 10px 12px;
  border: 1px solid var(--line);
  background: #fff;
}
.card .label {
  display: block;
  font-size: 11px;
  text-transform: uppercase;
  letter-spacing: 0.06em;
  color: var(--muted);
}
.card .value {
  display: block;
  margin-top: 6px;
  font-size: 20px;
  font-weight: 700;
  letter-spacing: -0.02em;
}
.card .sub {
  display: block;
  margin-top: 4px;
  color: var(--muted);
  font-size: 12px;
}
.layout {
  display: grid;
  grid-template-columns: minmax(0, 1.3fr) minmax(340px, 0.7fr);
  gap: 16px;
  padding: 16px 18px 18px;
  align-items: start;
}
.panel {
  background: var(--panel);
  border: 1px solid var(--line);
}
.panel-head {
  padding: 14px 16px 10px;
  border-bottom: 1px solid var(--line);
}
.panel-head h2 {
  margin: 0;
  font-size: 13px;
  text-transform: uppercase;
  letter-spacing: 0.08em;
  color: var(--muted);
}
.panel-head p {
  margin: 8px 0 0;
  font-size: 13px;
  color: var(--muted);
  line-height: 1.45;
}
.panel-body { padding: 12px 16px 16px; }
.legend {
  display: flex;
  flex-wrap: wrap;
  gap: 8px;
  margin-top: 12px;
}
.chip {
  display: inline-flex;
  align-items: center;
  gap: 8px;
  padding: 6px 9px;
  background: #fff;
  border: 1px solid var(--line);
  font-size: 12px;
  color: var(--ink);
}
.chip .swatch {
  width: 10px;
  height: 10px;
  border-radius: 2px;
}
.pareto-wrap {
  border: 1px solid var(--line);
  background: #fff;
  padding: 10px;
}
#pareto-chart {
  width: 100%;
  height: 420px;
  display: block;
}
.bucket-list, .files { display: grid; gap: 8px; }
.bucket-item {
  width: 100%;
  padding: 10px 12px;
  border: 1px solid var(--line);
  background: #fff;
  cursor: pointer;
  text-align: left;
  color: inherit;
}
.bucket-item.active {
  border-color: var(--accent);
  background: #fcfffe;
}
.bucket-head, .file-head {
  display: flex;
  justify-content: space-between;
  gap: 10px;
  align-items: baseline;
}
.bucket-name, .detail-title {
  font-size: 22px;
  font-weight: 700;
  letter-spacing: -0.02em;
}
.bucket-name {
  font-size: 14px;
  letter-spacing: -0.01em;
}
.bucket-meta, .file-meta {
  font-size: 12px;
  color: var(--muted);
  white-space: nowrap;
}
.bucket-sub, .file-sub {
  margin-top: 6px;
  display: flex;
  justify-content: space-between;
  flex-wrap: wrap;
  gap: 12px;
  color: var(--muted);
  font-size: 12px;
}
.meter {
  height: 10px;
  margin-top: 10px;
  background: #ece6db;
  overflow: hidden;
}
.meter > span {
  display: block;
  height: 100%;
  background: linear-gradient(90deg, var(--accent), var(--accent-soft));
}
.detail-meta {
  margin-top: 6px;
  color: var(--muted);
  font-size: 13px;
}
.detail-grid {
  display: grid;
  grid-template-columns: repeat(3, minmax(0, 1fr));
  gap: 8px;
  margin-top: 12px;
}
.detail-card {
  padding: 10px 12px;
  border: 1px solid var(--line);
  background: #fff;
}
.detail-card .label {
  display: block;
  font-size: 11px;
  letter-spacing: 0.06em;
  text-transform: uppercase;
  color: var(--muted);
}
.detail-card .value {
  display: block;
  margin-top: 6px;
  font-size: 20px;
  font-weight: 700;
}
.file-item {
  padding: 10px 12px;
  border: 1px solid var(--line);
  background: #fff;
}
.file-name {
  font: 12px "Iosevka Term", "SFMono-Regular", monospace;
  font-weight: 700;
  overflow-wrap: anywhere;
}
.empty {
  padding: 20px;
  border: 1px solid var(--line);
  background: #fff;
  color: var(--muted);
}
.help {
  margin-top: 16px;
  padding: 12px;
  border: 1px solid var(--line);
  background: #fff;
  color: var(--muted);
  font-size: 12px;
  line-height: 1.5;
}
@media (max-width: 1100px) {
  .layout { grid-template-columns: 1fr; }
  .detail-grid { grid-template-columns: 1fr 1fr; }
}
@media (max-width: 640px) {
  header { padding: 16px; }
  .layout { padding: 14px; }
  header h1 { font-size: 22px; }
  .detail-grid { grid-template-columns: 1fr; }
}
</style>
</head>
<body>
<header>
  <h1>vmlinux .text rollup -- subsystem breakdown</h1>
  <p>Total: __TOTAL__ bytes. Top-level buckets are sorted descending, so the left column is the fastest way to compare subsystem proportions. Click a bucket to inspect which files dominate that bucket. Special buckets:
     <code>&lt;icf-merged&gt;</code>, <code>&lt;unknown&gt;</code>,
     <code>&lt;compiler-partition&gt;</code>, <code>&lt;external&gt;</code>.</p>
  <div class="summary" id="summary"></div>
</header>
<main class="layout">
  <section class="panel">
    <div class="panel-head">
      <h2>Pareto View</h2>
      <p>橫條是各 subsystem 的 resident <code>.text</code> bytes，折線是累積百分比。先看前幾名就能抓到主要體積來源。</p>
      <div class="legend">
        <div class="chip"><span class="swatch" style="background:#1f6f78"></span>normal subsystem buckets</div>
        <div class="chip"><span class="swatch" style="background:#b24a35"></span>special attribution buckets</div>
      </div>
    </div>
    <div class="panel-body">
      <div class="pareto-wrap">
        <svg id="pareto-chart" viewBox="0 0 960 420" preserveAspectRatio="xMidYMid meet"></svg>
      </div>
      <div class="bucket-list" id="bucket-list"></div>
    </div>
  </section>
  <aside class="panel">
    <div class="panel-head">
      <h2>Selected Bucket</h2>
      <p>Largest contributing files inside the chosen subsystem.</p>
    </div>
    <div class="panel-body">
      <div id="detail"></div>
      <div class="help">This view is optimized for comparing proportions, not spatial packing. Use the left column to rank buckets; use the right column to understand why a bucket is large.</div>
    </div>
  </aside>
</main>
<script>
const data = __DATA__;
const summary = document.getElementById("summary");
const paretoChart = document.getElementById("pareto-chart");
const bucketList = document.getElementById("bucket-list");
const detail = document.getElementById("detail");
const normalPalette = ["#1f6f78", "#2f998d", "#3f8a58", "#2c5c84", "#7f8c3a", "#6f78b5"];
const specialPalette = ["#b24a35", "#c7684f", "#9b5a26", "#8e3f2d"];

function classify(name) {
  return name.startsWith("<") ? "special" : "normal";
}

function colorForBucket(name, index) {
  const colors = classify(name) === "special" ? specialPalette : normalPalette;
  return colors[index % colors.length];
}

function sum(items, fn) {
  let total = 0;
  for (const item of items) total += fn(item);
  return total;
}

function pct(part, whole) {
  return whole ? (part * 100 / whole) : 0;
}

function esc(text) {
  return String(text)
    .replaceAll("&", "&amp;")
    .replaceAll("<", "&lt;")
    .replaceAll(">", "&gt;");
}

const buckets = [...data.children]
  .map((bucket, index) => {
    const total = bucket.children.reduce((s, x) => s + x.value, 0);
    const symbols = bucket.children.reduce((s, x) => s + (x.symbols || 0), 0);
    return {
      ...bucket,
      total,
      symbols,
      colorIndex: index,
      files: [...bucket.children].sort((a, b) => b.value - a.value),
    };
  })
  .sort((a, b) => b.total - a.total)
  .map((bucket, index) => ({...bucket, rank: index + 1}));

const grandTotal = buckets.reduce((s, b) => s + b.total, 0);
let selected = buckets[0] || null;

function renderSummary() {
  const special = buckets.filter(b => classify(b.name) === "special");
  const largest = buckets[0];
  const cards = [
    { label: "Resident .text", value: grandTotal.toLocaleString(), sub: "bytes across all buckets" },
    { label: "Buckets", value: buckets.length, sub: `${special.length} special attribution buckets` },
    { label: "Largest Bucket", value: largest ? largest.name : "n/a", sub: largest ? `${largest.total.toLocaleString()} bytes` : "" },
    { label: "Attributed Leaves", value: sum(buckets, b => b.files.length).toLocaleString(), sub: "file-level entries" },
  ];
  summary.innerHTML = cards.map(d =>
    `<div class="card"><span class="label">${d.label}</span><span class="value">${d.value}</span><span class="sub">${d.sub}</span></div>`
  ).join("");
}

function renderBucketList() {
  const max = buckets.length ? buckets[0].total : 1;
  bucketList.innerHTML = buckets.map(bucket => {
    const share = pct(bucket.total, grandTotal);
    const width = pct(bucket.total, max);
    const active = selected && selected.name === bucket.name ? " active" : "";
    const color = colorForBucket(bucket.name, bucket.colorIndex);
    return `
      <button class="bucket-item${active}" data-bucket="${bucket.name}">
        <div class="bucket-head">
          <div class="bucket-name">${bucket.rank}. ${esc(bucket.name)}</div>
          <div class="bucket-meta">${bucket.total.toLocaleString()} bytes</div>
        </div>
        <div class="bucket-sub">
          <span>${share.toFixed(1)}% of total .text</span>
          <span>${bucket.symbols.toLocaleString()} symbols</span>
          <span>${bucket.files.length} files</span>
        </div>
        <div class="meter"><span style="width:${width.toFixed(1)}%; background:${color};"></span></div>
      </button>
    `;
  }).join("");

  for (const node of bucketList.querySelectorAll(".bucket-item")) {
    node.addEventListener("click", () => {
      selected = buckets.find(b => b.name === node.dataset.bucket) || selected;
      renderBucketList();
      renderDetail();
    });
  }
}

function renderParetoChart() {
  const w = 960;
  const h = 420;
  const margin = {top: 18, right: 64, bottom: 84, left: 76};
  const innerW = w - margin.left - margin.right;
  const innerH = h - margin.top - margin.bottom;
  const maxBytes = buckets.length ? buckets[0].total : 1;
  let cumulative = 0;
  const points = [];
  const barGap = 6;
  const barW = buckets.length ? Math.max(6, (innerW - (buckets.length - 1) * barGap) / buckets.length) : innerW;

  let html = `
    <rect x="0" y="0" width="${w}" height="${h}" fill="#fffdf9"></rect>
    <line x1="${margin.left}" y1="${margin.top}" x2="${margin.left}" y2="${margin.top + innerH}" stroke="#bfb6a8" />
    <line x1="${margin.left}" y1="${margin.top + innerH}" x2="${margin.left + innerW}" y2="${margin.top + innerH}" stroke="#bfb6a8" />
  `;

  for (let i = 0; i <= 4; i++) {
    const y = margin.top + innerH - innerH * (i / 4);
    const pctLabel = Math.round((i / 4) * 100);
    html += `<line x1="${margin.left}" y1="${y}" x2="${margin.left + innerW}" y2="${y}" stroke="#eee7da" />`;
    html += `<text x="${margin.left - 10}" y="${y + 4}" text-anchor="end" fill="#66757c" font-size="11">${pctLabel}%</text>`;
  }

  buckets.forEach((bucket, i) => {
    const x = margin.left + i * (barW + barGap);
    const barH = maxBytes ? (bucket.total / maxBytes) * innerH : 0;
    const y = margin.top + innerH - barH;
    cumulative += bucket.total;
    const cumPct = pct(cumulative, grandTotal);
    const py = margin.top + innerH - (cumPct / 100) * innerH;
    points.push(`${x + barW / 2},${py}`);
    const color = colorForBucket(bucket.name, bucket.colorIndex);
    const active = selected && selected.name === bucket.name;
    html += `<rect x="${x}" y="${y}" width="${barW}" height="${barH}" fill="${color}" stroke="${active ? '#111' : 'none'}" stroke-width="2" data-bucket="${esc(bucket.name)}"></rect>`;
    html += `<text x="${x + barW / 2}" y="${margin.top + innerH + 14}" text-anchor="end" transform="rotate(-55 ${x + barW / 2} ${margin.top + innerH + 14})" fill="#66757c" font-size="10">${esc(bucket.name)}</text>`;
  });

  html += `<polyline fill="none" stroke="#111" stroke-width="2.5" points="${points.join(" ")}"></polyline>`;
  points.forEach((pt, i) => {
    const [cx, cy] = pt.split(",");
    html += `<circle cx="${cx}" cy="${cy}" r="${selected && selected.name === buckets[i].name ? 4.5 : 3.5}" fill="#111"></circle>`;
  });
  html += `<text x="${margin.left}" y="${h - 8}" fill="#66757c" font-size="11">bars = bytes, line = cumulative share</text>`;
  html += `<text x="${w - 8}" y="${margin.top + 12}" text-anchor="end" fill="#66757c" font-size="11">100%</text>`;
  paretoChart.innerHTML = html;

  paretoChart.querySelectorAll("[data-bucket]").forEach((node) => {
    node.style.cursor = "pointer";
    node.addEventListener("click", () => {
      selected = buckets.find(b => b.name === node.getAttribute("data-bucket")) || selected;
      renderParetoChart();
      renderBucketList();
      renderDetail();
    });
  });
}

function renderDetail() {
  if (!selected) {
    detail.innerHTML = '<div class="empty">No bucket data.</div>';
    return;
  }
  const share = pct(selected.total, grandTotal);
  const topFiles = selected.files.slice(0, 18);
  const maxFile = topFiles.length ? topFiles[0].value : 1;
  const color = colorForBucket(selected.name, selected.colorIndex);
  detail.innerHTML = `
    <h3 class="detail-title">${selected.name}</h3>
    <div class="detail-meta">${selected.total.toLocaleString()} bytes, ${share.toFixed(2)}% of total resident .text, ${selected.files.length} file entries</div>
    <div class="detail-grid">
      <div class="detail-card"><span class="label">Bucket Bytes</span><span class="value">${selected.total.toLocaleString()}</span></div>
      <div class="detail-card"><span class="label">Share of Total</span><span class="value">${share.toFixed(2)}%</span></div>
      <div class="detail-card"><span class="label">Clones / ICF</span><span class="value">${selected.clones || 0} / ${selected.icf || 0}</span></div>
    </div>
    <div class="files">
      ${topFiles.map((file, i) => {
        const fileShareBucket = pct(file.value, selected.total);
        const fileShareTotal = pct(file.value, grandTotal);
        const width = pct(file.value, maxFile);
        return `
          <div class="file-item">
            <div class="file-head">
          <div class="file-name">${i + 1}. ${esc(file.name)}</div>
              <div class="file-meta">${file.value.toLocaleString()} bytes</div>
            </div>
            <div class="file-sub">
              <span>${fileShareBucket.toFixed(1)}% of bucket</span>
              <span>${fileShareTotal.toFixed(2)}% of total</span>
              <span>${file.symbols || 0} symbols</span>
            </div>
            <div class="meter"><span style="width:${width.toFixed(1)}%; background:${color};"></span></div>
          </div>
        `;
      }).join("")}
    </div>
  `;
}

renderSummary();
renderParetoChart();
renderBucketList();
renderDetail();
</script>
</body>
</html>
"""


def write_deep_table(buckets, deep_buckets, path, top_files=20):
    # Per-bucket source-file breakdown for buckets the operator named.
    # Same `BucketAgg.files` data that feeds the treemap, rolled up two
    # ways: by 2nd-level subdirectory (`kernel/sched/fair.c` ->
    # `kernel/sched`) and as a flat top-N file list. The `<unfiled>`
    # pseudo-key inside `b.files` (entries the aggregator could not
    # attribute to a path) is suppressed -- it duplicates the parent
    # bucket's <unknown>/<external> bookkeeping and would make the
    # depth-2 totals overshoot.
    lines = [
        "# subsystem-rollup-deep -- per-bucket source breakdown",
        "# Same attribution rules as subsystem-rollup.txt; this file",
        "# drills one level deeper for the buckets named via --deep.",
        f"# requested buckets: {', '.join(deep_buckets)}",
        "",
    ]
    for bname in deep_buckets:
        b = buckets.get(bname)
        if b is None or not b.files:
            lines.append(f"## {bname} -- not present in this rollup")
            lines.append("")
            continue

        bucket_total = b.bytes
        attributed = [
            (fname, finfo) for fname, finfo in b.files.items()
            if fname != "<unfiled>"
        ]
        n_files = len(attributed)
        lines.append(
            f"## {bname} -- {bucket_total} bytes across {n_files} "
            f"source files"
        )
        lines.append("")

        depth2 = collections.defaultdict(
            lambda: {"bytes": 0, "symbols": 0, "files": set()}
        )
        for fname, finfo in attributed:
            parts = fname.split("/")
            # parts[:2] keeps single-component names like
            # "kernel/workqueue.c" intact AND collapses
            # "kernel/sched/fair.c" -> "kernel/sched".
            key = "/".join(parts[: min(2, len(parts))])
            d = depth2[key]
            d["bytes"] += finfo["bytes"]
            d["symbols"] += finfo["symbols"]
            d["files"].add(fname)

        lines.append(f"# {bname} by 2nd-level subdirectory")
        lines.append("# subdirectory\tbytes\tpercent\tsymbols\tfiles")
        for key, d in sorted(
            depth2.items(), key=lambda kv: kv[1]["bytes"], reverse=True
        ):
            pct = d["bytes"] * 100.0 / bucket_total if bucket_total else 0.0
            lines.append(
                f"{key}\t{d['bytes']}\t{pct:.2f}\t"
                f"{d['symbols']}\t{len(d['files'])}"
            )
        lines.append("")

        lines.append(f"# {bname} top {top_files} source files")
        lines.append("# file\tbytes\tpercent\tsymbols")
        for fname, finfo in sorted(
            attributed, key=lambda kv: kv[1]["bytes"], reverse=True
        )[:top_files]:
            pct = finfo["bytes"] * 100.0 / bucket_total if bucket_total else 0.0
            lines.append(
                f"{fname}\t{finfo['bytes']}\t{pct:.2f}\t{finfo['symbols']}"
            )
        lines.append("")

    path.write_text("\n".join(lines) + "\n")


DEEP_HTML = """<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8"/>
<title>vmlinux .text rollup -- deep breakdown</title>
<style>
:root {
  --bg: #f5efe4;
  --panel: rgba(255, 252, 246, 0.88);
  --panel-border: rgba(74, 88, 92, 0.14);
  --ink: #1f2e33;
  --muted: #5a6a6f;
  --accent: #1f6f78;
  --accent-2: #2f998d;
  --shadow: 0 18px 40px rgba(45, 44, 37, 0.12);
}
* { box-sizing: border-box; }
body { margin: 0; font-family: "Avenir Next", "Segoe UI", "Helvetica Neue", sans-serif;
       background: linear-gradient(180deg, #f7f1e7 0%, var(--bg) 100%);
       color: var(--ink); }
header { padding: 18px 22px; border-bottom: 1px solid var(--panel-border);
         background: var(--panel); position: sticky; top: 0; z-index: 10;
         backdrop-filter: blur(10px); box-shadow: var(--shadow); }
.eyebrow { display:inline-block; margin-bottom:8px; padding:5px 10px; border-radius:999px;
           background: rgba(31,111,120,0.10); color: var(--accent);
           font-size: 11px; letter-spacing: 0.08em; text-transform: uppercase; font-weight: 700; }
header h1 { margin: 0; font-size: 24px; letter-spacing: -0.02em; }
header p { margin: 8px 0 0; font-size: 13px; color: var(--muted); max-width: 980px; line-height: 1.45; }
header code { background: rgba(33, 54, 59, 0.08); padding: 2px 6px; border-radius: 999px;
              font-family: "Iosevka Term", "SFMono-Regular", monospace; }
nav { margin-top: 12px; font-size: 12px; display: flex; flex-wrap: wrap; gap: 8px; }
nav a { color: #1f4854; text-decoration: none; padding: 7px 10px; border-radius: 999px;
        background: rgba(255,255,255,0.72); border: 1px solid rgba(74,88,92,0.10); }
nav a:hover { background: rgba(31,111,120,0.10); }
main { padding: 16px; display: grid; gap: 16px; }
section { padding: 18px 20px; border: 1px solid var(--panel-border);
          background: rgba(255,252,246,0.82); border-radius: 18px; box-shadow: var(--shadow); }
section h2 { margin: 0 0 4px; font-size: 18px; letter-spacing: -0.02em; }
section h3 { margin: 18px 0 8px; font-size: 11px; color: var(--muted);
             text-transform: uppercase; letter-spacing: 0.08em; }
section .meta { font-size: 13px; color: var(--muted); }
table { border-collapse: collapse; width: 100%; max-width: 980px;
        font: 12px "Iosevka Term", "SFMono-Regular", monospace; margin-top: 8px;
        background: rgba(255,255,255,0.62); border-radius: 14px; overflow: hidden; }
th, td { border-bottom: 1px solid rgba(74,88,92,0.10); padding: 7px 10px; text-align: left;
         vertical-align: top; white-space: nowrap; }
th { font-weight: 600; color: #3f4f55; background: rgba(226, 220, 209, 0.92); }
tbody tr:nth-child(even) { background: rgba(245, 242, 235, 0.72); }
tbody tr:hover { background: rgba(31, 111, 120, 0.08); }
td.num { text-align: right; font-variant-numeric: tabular-nums; }
.bar { position: relative; height: 14px; background: rgba(39, 58, 63, 0.10);
       border-radius: 999px; overflow: hidden; min-width: 120px; }
.bar > span { position: absolute; left: 0; top: 0; bottom: 0;
              background: linear-gradient(90deg, var(--accent), var(--accent-2));
              border-radius: 999px; }
footer { padding: 10px 20px 18px; font-size: 11px; color: #7a827f; }
@media (max-width: 700px) {
  header { padding: 16px; }
  main { padding: 12px; }
  section { padding: 16px; }
}
</style>
</head>
<body>
<header>
  <div class="eyebrow">LTO-Aware Attribution</div>
  <h1>vmlinux .text rollup -- deep breakdown</h1>
  <p>Per-bucket 2nd-level subdirectory rollup and top source files.
     Same attribution rules as <code>subsystem-rollup.txt</code>;
     hover bars to read exact byte counts.</p>
  <nav>__NAV__</nav>
</header>
<main>__BODY__</main>
<footer>Generated by <code>scripts/subsystem-rollup.py --deep</code>.</footer>
</body>
</html>
"""


def write_deep_html(buckets, deep_buckets, path, top_files=20):
    sections = []
    nav = []
    for bname in deep_buckets:
        anchor = (
            "b-" + re.sub(r"[^A-Za-z0-9]+", "-", bname).strip("-").lower()
        )
        nav.append(f'<a href="#{anchor}">{xml.sax.saxutils.escape(bname)}</a>')

        b = buckets.get(bname)
        if b is None or not b.files:
            sections.append(
                f'<section id="{anchor}"><h2>{_esc(bname)}</h2>'
                f'<p class="meta">not present in this rollup</p></section>'
            )
            continue

        bucket_total = b.bytes
        attributed = [
            (fname, finfo) for fname, finfo in b.files.items()
            if fname != "<unfiled>"
        ]
        n_files = len(attributed)

        depth2 = collections.defaultdict(
            lambda: {"bytes": 0, "symbols": 0, "files": set()}
        )
        for fname, finfo in attributed:
            parts = fname.split("/")
            key = "/".join(parts[: min(2, len(parts))])
            d = depth2[key]
            d["bytes"] += finfo["bytes"]
            d["symbols"] += finfo["symbols"]
            d["files"].add(fname)

        depth2_rows = sorted(
            depth2.items(), key=lambda kv: kv[1]["bytes"], reverse=True
        )
        max_d2 = max((d["bytes"] for _, d in depth2_rows), default=1) or 1
        depth2_html = ['<h3>2nd-level subdirectories</h3>',
                       '<table><thead><tr>'
                       '<th>subdirectory</th><th class="num">bytes</th>'
                       '<th class="num">%</th><th class="num">symbols</th>'
                       '<th class="num">files</th><th>share</th>'
                       '</tr></thead><tbody>']
        for key, d in depth2_rows:
            pct = d["bytes"] * 100.0 / bucket_total if bucket_total else 0.0
            bar_pct = d["bytes"] * 100.0 / max_d2
            depth2_html.append(
                f'<tr><td>{_esc(key)}</td>'
                f'<td class="num">{d["bytes"]:,}</td>'
                f'<td class="num">{pct:.2f}</td>'
                f'<td class="num">{d["symbols"]}</td>'
                f'<td class="num">{len(d["files"])}</td>'
                f'<td><div class="bar" title="{d["bytes"]:,} bytes">'
                f'<span style="width:{bar_pct:.1f}%"></span></div></td>'
                '</tr>'
            )
        depth2_html.append('</tbody></table>')

        files_rows = sorted(
            attributed, key=lambda kv: kv[1]["bytes"], reverse=True
        )[:top_files]
        max_f = max((f["bytes"] for _, f in files_rows), default=1) or 1
        files_html = [
            f'<h3>top {top_files} source files</h3>',
            '<table><thead><tr>'
            '<th>file</th><th class="num">bytes</th>'
            '<th class="num">%</th><th class="num">symbols</th>'
            '<th>share</th>'
            '</tr></thead><tbody>'
        ]
        for fname, finfo in files_rows:
            pct = finfo["bytes"] * 100.0 / bucket_total if bucket_total else 0.0
            bar_pct = finfo["bytes"] * 100.0 / max_f
            files_html.append(
                f'<tr><td>{_esc(fname)}</td>'
                f'<td class="num">{finfo["bytes"]:,}</td>'
                f'<td class="num">{pct:.2f}</td>'
                f'<td class="num">{finfo["symbols"]}</td>'
                f'<td><div class="bar" title="{finfo["bytes"]:,} bytes">'
                f'<span style="width:{bar_pct:.1f}%"></span></div></td>'
                '</tr>'
            )
        files_html.append('</tbody></table>')

        sections.append(
            f'<section id="{anchor}">'
            f'<h2>{_esc(bname)}</h2>'
            f'<p class="meta">{bucket_total:,} bytes across {n_files} '
            f'source files</p>'
            + "\n".join(depth2_html)
            + "\n".join(files_html)
            + '</section>'
        )

    html = (
        DEEP_HTML
        .replace("__NAV__", " ".join(nav) if nav else "(no buckets)")
        .replace("__BODY__", "\n".join(sections))
    )
    path.write_text(html)


def write_treemap(buckets, grand_total, path):
    children = []
    for bname, b in sorted(
        buckets.items(), key=lambda kv: kv[1].bytes, reverse=True
    ):
        files = []
        for fname, finfo in sorted(
            b.files.items(), key=lambda kv: kv[1]["bytes"], reverse=True
        ):
            files.append({
                "name": fname,
                "value": finfo["bytes"],
                "symbols": finfo["symbols"],
            })
        if not files:
            files = [{"name": bname, "value": b.bytes, "symbols": b.symbols}]
        children.append({
            "name": bname,
            "icf": b.icf,
            "clones": b.clones,
            "children": files,
        })
    root = {"name": "vmlinux .text", "children": children}
    data = json.dumps(root, separators=(",", ":"))
    html = (
        TREEMAP_HTML
        .replace("__DATA__", data)
        .replace("__TOTAL__", f"{grand_total:,}")
    )
    path.write_text(html)


def main(argv):
    parser = argparse.ArgumentParser(
        description="LTO-aware vmlinux .text rollup by source subsystem."
    )
    parser.add_argument("--vmlinux", required=True, type=pathlib.Path)
    parser.add_argument(
        "--linux-tree",
        type=pathlib.Path,
        help="Kernel source tree (used to strip absolute paths).",
    )
    parser.add_argument(
        "--toolchain-bin",
        type=pathlib.Path,
        help="Toolchain bin/ directory (overrides PATH lookup).",
    )
    parser.add_argument(
        "--output",
        required=True,
        type=pathlib.Path,
        help="Path to subsystem-rollup.txt; the SVG and HTML siblings "
        "are written next to it.",
    )
    parser.add_argument(
        "--batch-size",
        type=int,
        default=4096,
        help="Addresses per addr2line invocation (default: 4096).",
    )
    parser.add_argument(
        "--deep",
        action="append",
        default=[],
        metavar="BUCKET",
        help="Bucket name to break down further into 2nd-level "
        "subdirs and top source files. Repeatable. When set, "
        "writes subsystem-rollup-deep.txt next to --output.",
    )
    parser.add_argument(
        "--deep-output",
        type=pathlib.Path,
        help="Override path for the deep-rollup output (defaults to "
        "subsystem-rollup-deep.txt next to --output).",
    )
    args = parser.parse_args(argv)

    if args.batch_size < 1:
        print(
            f"subsystem-rollup: --batch-size must be >= 1 "
            f"(got {args.batch_size})",
            file=sys.stderr,
        )
        return 1

    # The deep emitter writes <path>.txt and derives the HTML sibling
    # via path.with_suffix('.html'). If the operator passes a
    # .html-suffixed --deep-output, the derived sibling collides with
    # the .txt write that just happened and silently overwrites it.
    # Catch that explicitly instead of producing a half-truncated pair.
    if (
        args.deep_output is not None
        and args.deep_output.suffix.lower() == ".html"
    ):
        print(
            "subsystem-rollup: --deep-output must be the .txt path "
            "(the .html sibling is derived from its stem); refusing "
            f"to alias the two files (got {args.deep_output})",
            file=sys.stderr,
        )
        return 1

    if not args.vmlinux.exists():
        print(
            f"subsystem-rollup: missing vmlinux: {args.vmlinux}",
            file=sys.stderr,
        )
        return 1

    toolchain_bin = args.toolchain_bin
    if toolchain_bin is None and args.linux_tree is not None:
        toolchain_bin = (
            args.linux_tree.resolve().parent / "toolchain" / "bin"
        )

    nm = resolve_tool("nm", toolchain_bin)
    addr2line = resolve_tool("addr2line", toolchain_bin)
    try:
        size_tool = resolve_tool("size", toolchain_bin)
    except FileNotFoundError:
        size_tool = None

    rows = collect_text_symbols(nm, args.vmlinux)
    if not rows:
        print(
            "subsystem-rollup: nm returned no sized text symbols",
            file=sys.stderr,
        )
        return 1

    tree_prefix = (
        str(args.linux_tree.resolve()) if args.linux_tree else ""
    )

    entries = build_deduped_entries(rows)
    if not entries:
        print(
            "subsystem-rollup: no entries after dedup",
            file=sys.stderr,
        )
        return 1

    addresses = [e["addr"] for e in entries]
    stacks = []
    for start in range(0, len(addresses), args.batch_size):
        chunk = addresses[start: start + args.batch_size]
        stacks.extend(resolve_inline_stacks(addr2line, args.vmlinux, chunk))

    buckets, accounted = aggregate(entries, stacks, tree_prefix)

    unknown_bytes = (
        buckets["<unknown>"].bytes if "<unknown>" in buckets else 0
    )
    if accounted and unknown_bytes / accounted > UNRESOLVED_FAIL_RATIO:
        print(
            f"subsystem-rollup: {unknown_bytes / accounted * 100:.1f}% "
            "of resolved .text is <unknown> -- vmlinux likely lacks "
            "DWARF. Re-build with KERNEL_DEBUG_INFO=reduced "
            "(CONFIG_DEBUG_INFO_REDUCED=y) for diagnostic attribution.",
            file=sys.stderr,
        )
        return 2

    if size_tool is not None:
        section_total = text_section_total(size_tool, args.vmlinux)
        if section_total and section_total > accounted:
            residual = section_total - accounted
            buckets["<compiler-partition>"].bytes += residual
            # No symbols claim these bytes; record the count as zero
            # rather than fabricating one. The bytes column is enough
            # to flag the residual when it grows.
    grand_total = sum(b.bytes for b in buckets.values())

    out = args.output
    out.parent.mkdir(parents=True, exist_ok=True)
    write_table(buckets, grand_total, out)
    write_svg(
        buckets, grand_total,
        out.with_name("subsystem-rollup-bars.svg"),
    )
    write_treemap(
        buckets, grand_total,
        out.with_name("subsystem-rollup-tree.html"),
    )
    if args.deep:
        deep_path = (
            args.deep_output
            if args.deep_output is not None
            else out.with_name("subsystem-rollup-deep.txt")
        )
        write_deep_table(buckets, args.deep, deep_path)
        write_deep_html(
            buckets, args.deep,
            deep_path.with_suffix(".html"),
        )
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
