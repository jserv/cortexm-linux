#!/usr/bin/env python3

# Roll up vmlinux .text bytes by source subsystem.
#
# Reads `nm -n -S` to get text symbols (address, size, name), feeds the
# addresses through one batched `addr2line -e vmlinux -f` invocation, and
# attributes each symbol to a top-level kernel directory. drivers/<subdir>/
# and arch/<arch>/<subdir>/ are split out so a single driver family does not
# hide inside the parent bucket.
#
# Symbols whose source location addr2line cannot resolve (no DWARF, inlined
# without debug info, etc.) land in the "<unknown>" bucket so the report
# always sums to the visible .text mass.

import argparse
import os
import pathlib
import re
import shutil
import subprocess
import sys
from typing import Optional


TEXT_TYPES = {"T", "t", "W", "w"}

# Kernel top-level directories that should each become their own bucket.
# Anything outside this set rolls up under the literal first path component
# (or "<external>" if the path is absolute and unrecognized).
TOP_LEVEL_DIRS = frozenset({
    "arch", "block", "certs", "crypto", "drivers", "fs", "init", "io_uring",
    "ipc", "kernel", "lib", "mm", "net", "rust", "samples", "scripts",
    "security", "sound", "tools", "usr", "virt",
})

# Subdirectories that are themselves large enough that splitting one level
# deeper is the right granularity, even though the parent already gets a
# bucket.
SPLIT_ONE_DEEPER = frozenset({"arch", "drivers", "sound", "net"})


def resolve_tool(name: str, toolchain_bin: Optional[pathlib.Path]) -> str:
    # Precedence: explicit --toolchain-bin > CROSS_COMPILE > PATH lookup.
    # An explicit flag must beat ambient env, otherwise a stray
    # CROSS_COMPILE pointing at a different toolchain silently produces
    # mismatched nm/addr2line and corrupt attribution.
    candidates = []
    if toolchain_bin is not None:
        candidates.append(str(toolchain_bin / ("arm-uclinuxfdpiceabi-" + name)))
    cross_compile = os.environ.get("CROSS_COMPILE", "")
    if cross_compile:
        candidates.append(cross_compile + name)
    candidates.append("arm-uclinuxfdpiceabi-" + name)

    for candidate in candidates:
        resolved = shutil.which(candidate) if not pathlib.Path(candidate).is_absolute() else candidate
        if resolved and pathlib.Path(resolved).exists():
            return resolved

    raise FileNotFoundError(f"unable to locate arm-uclinuxfdpiceabi-{name}")


def collect_text_symbols(nm: str, vmlinux: pathlib.Path):
    cmd = [nm, "-n", "-S", "--defined-only", str(vmlinux)]
    proc = subprocess.run(cmd, check=True, text=True, capture_output=True)
    rows = []
    for line in proc.stdout.splitlines():
        fields = line.split(None, 3)
        if len(fields) != 4:
            continue
        addr_hex, size_hex, sym_type, name = fields
        # Defensive: a name that contains whitespace would push a non-hex
        # token into size_hex / sym_type. Cheap to guard, avoids a hard
        # crash on a single malformed line.
        if len(sym_type) != 1 or sym_type not in TEXT_TYPES:
            continue
        try:
            size = int(size_hex, 16)
            addr = int(addr_hex, 16)
        except ValueError:
            continue
        if size == 0:
            continue
        # Thumb function symbols carry the low bit set; addr2line wants the
        # even instruction address.
        rows.append((addr & ~1, size, name))
    return rows


def resolve_addresses(addr2line: str, vmlinux: pathlib.Path, addresses):
    # addr2line -f without -i emits exactly two lines per input: function
    # name, then file:line. Feeding a long list as stdin keeps this to one
    # subprocess instead of the per-symbol fork/exec storm that
    # scripts/faddr2line incurs.
    cmd = [addr2line, "-e", str(vmlinux), "-f"]
    payload = "\n".join(f"0x{a:x}" for a in addresses) + "\n"
    proc = subprocess.run(cmd, input=payload, check=True, text=True, capture_output=True)
    lines = proc.stdout.splitlines()
    expected = len(addresses) * 2
    if len(lines) != expected:
        raise RuntimeError(
            f"addr2line returned {len(lines)} lines, expected {expected}"
        )
    out = []
    for i in range(0, len(lines), 2):
        # function name on lines[i] is unused; file:line is what we bucket on.
        location = lines[i + 1]
        out.append(location)
    return out


# Match "/abs/.../source/file.c:123 (discriminator N)" or "??:0".
LINE_RE = re.compile(r"^(?P<path>.*?):[0-9?]+(?:\s+\(discriminator.*\))?$")


def normalize_path(location: str, tree_prefix: str):
    m = LINE_RE.match(location)
    if not m:
        return None
    path = m.group("path")
    if path in ("", "??"):
        return None

    # addr2line returns absolute paths from the build's working directory.
    # Strip the kernel source prefix so paths become relative to the kernel
    # tree root. The boundary check ("/" suffix or exact match) prevents a
    # sibling directory like `/home/u/linux-build/...` from being treated
    # as a child of `/home/u/linux/`.
    if tree_prefix and (path == tree_prefix or path.startswith(tree_prefix + "/")):
        path = path[len(tree_prefix):].lstrip("/")
    elif path.startswith("/"):
        # Fall back to the first known top-level directory in the path.
        parts = path.split("/")
        for idx, part in enumerate(parts):
            if part in TOP_LEVEL_DIRS:
                path = "/".join(parts[idx:])
                break
        else:
            return path  # absolute, unrecognized -- leave for "<external>"
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


def render_report(buckets, total_text):
    lines = []
    lines.append(f"# .text rollup -- total resolved bytes: {total_text}")
    lines.append("# bucket\tbytes\tpercent")
    rows = sorted(buckets.items(), key=lambda kv: kv[1], reverse=True)
    for name, size in rows:
        pct = (size * 100.0 / total_text) if total_text else 0.0
        lines.append(f"{name}\t{size}\t{pct:.2f}")
    return "\n".join(lines) + "\n"


def main(argv):
    parser = argparse.ArgumentParser(
        description="Attribute vmlinux .text bytes to source subsystems."
    )
    parser.add_argument("--vmlinux", required=True, type=pathlib.Path)
    parser.add_argument(
        "--linux-tree",
        type=pathlib.Path,
        help="Path to the kernel source tree (used to strip absolute paths).",
    )
    parser.add_argument(
        "--toolchain-bin",
        type=pathlib.Path,
        help="Toolchain bin/ directory (overrides PATH lookup).",
    )
    parser.add_argument("--output", required=True, type=pathlib.Path)
    parser.add_argument(
        "--batch-size",
        type=int,
        default=4096,
        help="Addresses per addr2line invocation (default: 4096).",
    )
    args = parser.parse_args(argv)

    if args.batch_size < 1:
        print(
            f"text-rollup: --batch-size must be >= 1 (got {args.batch_size})",
            file=sys.stderr,
        )
        return 1

    vmlinux = args.vmlinux
    if not vmlinux.exists():
        print(f"text-rollup: missing vmlinux: {vmlinux}", file=sys.stderr)
        return 1

    toolchain_bin = args.toolchain_bin
    if toolchain_bin is None and args.linux_tree is not None:
        toolchain_bin = args.linux_tree.resolve().parent / "toolchain" / "bin"

    nm = resolve_tool("nm", toolchain_bin)
    addr2line = resolve_tool("addr2line", toolchain_bin)

    rows = collect_text_symbols(nm, vmlinux)
    if not rows:
        print("text-rollup: no text symbols with size found", file=sys.stderr)
        return 1

    tree_prefix = ""
    if args.linux_tree:
        tree_prefix = str(args.linux_tree.resolve())

    # nm -nS already address-sorts; re-sort defensively so the overlap
    # clamp below cannot be defeated by a symbol whose address ties an
    # earlier one. Kernel ARM entry-point macros emit multiple T symbols
    # covering the same code blob (e.g. `ret_to_user` at +0 and
    # `ret_to_user_from_irq` at +4 with the same end address); summing
    # their reported sizes would double-count the shared region.
    rows.sort(key=lambda r: r[0])
    starts = [r[0] for r in rows]

    buckets = {}
    total = 0
    for start in range(0, len(rows), args.batch_size):
        chunk = rows[start:start + args.batch_size]
        addresses = [addr for addr, _, _ in chunk]
        locations = resolve_addresses(addr2line, vmlinux, addresses)
        for idx, ((addr, size, _), loc) in enumerate(zip(chunk, locations)):
            row_idx = start + idx
            next_addr = starts[row_idx + 1] if row_idx + 1 < len(starts) else addr + size
            effective = min(size, max(0, next_addr - addr))
            if effective <= 0:
                continue
            path = normalize_path(loc, tree_prefix)
            key = bucket_for(path)
            buckets[key] = buckets.get(key, 0) + effective
            total += effective

    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(render_report(buckets, total))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
