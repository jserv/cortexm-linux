#!/usr/bin/env python3

import argparse
import pathlib
import re
import sys


ENTRY_RE = re.compile(r"^(\d+)\s+\d+\s+")
DEFAULT_PRESERVE_NAMES = {
    "restart_syscall",  # kernel-initiated after signal, not visible as SVC
    "exit",
    "brk",
    "munmap",           # FDPIC dynamic linker (ld-uClibc.so)
    "sigreturn",        # kernel-initiated signal return
    "mprotect",         # FDPIC dynamic linker
    "rt_sigreturn",     # kernel-initiated signal return
    "rt_sigaction",     # signal setup, may not fire during trace window
    "rt_sigprocmask",   # signal mask, may not fire during trace window
    "mmap2",            # FDPIC dynamic linker
    "futex",
    "exit_group",
    "set_tid_address",
    "set_robust_list",
}


def load_used_syscalls(report_path: pathlib.Path):
    used = set()
    for line in report_path.read_text(encoding="utf-8", errors="replace").splitlines():
        match = ENTRY_RE.match(line.strip())
        if match:
            used.add(int(match.group(1)))
    return used


def rewrite_table(
    syscall_table: pathlib.Path,
    output_table: pathlib.Path,
    report_path: pathlib.Path,
    used,
    preserved_numbers,
    preserved_names,
):
    patched = []
    kept = []
    lines_out = []

    for raw in syscall_table.read_text(encoding="utf-8", errors="replace").splitlines():
        stripped = raw.strip()
        if not stripped or stripped.startswith("#"):
            lines_out.append(raw)
            continue

        fields = stripped.split()
        if len(fields) < 4:
            lines_out.append(raw)
            continue

        try:
            number = int(fields[0])
        except ValueError:
            lines_out.append(raw)
            continue

        abi, name, entry = fields[1], fields[2], fields[3]
        compat = fields[4] if len(fields) > 4 else None
        if entry == "sys_ni_syscall" or number in used:
            lines_out.append(raw)
            continue

        if number in preserved_numbers or name in preserved_names:
            lines_out.append(raw)
            kept.append((number, abi, name, entry, compat))
            continue

        fields[3] = "sys_ni_syscall"
        if compat is not None:
            fields[4] = "sys_ni_syscall"
        lines_out.append("\t".join(fields))
        patched.append((number, abi, name, entry, compat))

    output_table.write_text("\n".join(lines_out) + "\n", encoding="utf-8")

    report_lines = [
        f"source_syscall_report={report_path}",
        f"used_syscall_count={len(used)}",
        f"preserved_syscall_count={len(kept)}",
        f"patched_syscall_count={len(patched)}",
        "preserved_syscalls:",
    ]
    for number, abi, name, entry, compat in kept:
        if compat is None:
            report_lines.append(f"{number} {abi} {name} {entry}")
        else:
            report_lines.append(f"{number} {abi} {name} {entry}/{compat}")

    report_lines.extend(
        [
        "patched_syscalls:",
        ]
    )
    for number, abi, name, entry, compat in patched:
        if compat is None:
            report_lines.append(f"{number} {abi} {name} {entry} -> sys_ni_syscall")
        else:
            report_lines.append(
                f"{number} {abi} {name} {entry}/{compat} -> sys_ni_syscall/sys_ni_syscall"
            )
    output_table.with_suffix(".report.txt").write_text(
        "\n".join(report_lines) + "\n", encoding="utf-8"
    )
    return patched


def main():
    parser = argparse.ArgumentParser(description="Generate a syscall.tbl candidate pruned to observed syscalls.")
    parser.add_argument("--syscall-report", required=True, type=pathlib.Path)
    parser.add_argument("--syscall-table", required=True, type=pathlib.Path)
    parser.add_argument("--output-table", required=True, type=pathlib.Path)
    parser.add_argument(
        "--keep-syscall",
        dest="keep_syscalls",
        action="append",
        type=int,
        default=[],
        help="Syscall number to preserve even if it is absent from the trace report",
    )
    parser.add_argument(
        "--keep-syscall-name",
        dest="keep_syscall_names",
        action="append",
        default=[],
        help="Syscall name to preserve even if it is absent from the trace report",
    )
    args = parser.parse_args()

    if not args.syscall_report.is_file():
        print(f"missing syscall report: {args.syscall_report}", file=sys.stderr)
        return 1
    if not args.syscall_table.is_file():
        print(f"missing syscall table: {args.syscall_table}", file=sys.stderr)
        return 1

    used = load_used_syscalls(args.syscall_report)
    if not used:
        print("no observed syscalls found in report", file=sys.stderr)
        return 1

    preserved_numbers = set(args.keep_syscalls)
    preserved_names = set(DEFAULT_PRESERVE_NAMES)
    preserved_names.update(args.keep_syscall_names)
    args.output_table.parent.mkdir(parents=True, exist_ok=True)
    rewrite_table(
        args.syscall_table,
        args.output_table,
        args.syscall_report,
        used,
        preserved_numbers,
        preserved_names,
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
