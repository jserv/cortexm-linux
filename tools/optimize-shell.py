#!/usr/bin/env python3
"""Host-side shell script optimizer.

The optimizer parses a whole shell script, collects rewrite opportunities as
source spans, and applies only conflict-free rewrites.  Rewrites are
intentionally conservative: if a pattern cannot be proven to preserve shell
semantics, it is left unchanged.

The immediate user is the Cortex-M NOMMU initramfs build, where replacing
subshells and pipelines avoids vfork/exec overhead.  The optimizer itself is
not init-specific: it can process any POSIX-ish shell script passed on stdin or
as a file path.

The parser lives in tools/shell_ast.py.  It exposes command-substitution
source spans without requiring a system Python package.
"""

from __future__ import annotations

import argparse
import difflib
import os
import re
import shlex
import sys
from dataclasses import dataclass
from typing import Any, Iterable

import shell_ast

VAR = r"[A-Za-z_][A-Za-z0-9_]*"
BARE = r"[A-Za-z0-9_./:+-]+"
DQ_VAR = r'"?\$(' + VAR + r')"?'
LITERAL_PATH = r"""(?:"(/[^"$`\\\n]*[^/"$`\\\n])"|'(/[^'\n]*/?[^/'\n])'|(/[^ \t\n)"'`\\]*/?[^/ \t\n)"'`\\]))"""


@dataclass(frozen=True)
class Rewrite:
    start: int
    end: int
    text: str
    reason: str


def iter_shell_nodes(node: Any) -> Iterable[Any]:
    yield node
    for value in getattr(node, "__dict__", {}).values():
        if isinstance(value, list):
            for item in value:
                if hasattr(item, "kind"):
                    yield from iter_shell_nodes(item)
        elif hasattr(value, "kind"):
            yield from iter_shell_nodes(value)


def command_substitution_spans(source: str) -> list[tuple[int, int]]:
    spans: list[tuple[int, int]] = []
    for tree in shell_ast.parse(source):
        for node in iter_shell_nodes(tree):
            if getattr(node, "kind", None) == "commandsubstitution":
                spans.append(node.pos)
    return spans


def shell_pattern_literal(text: str) -> str:
    return "".join("\\" + ch if ch in "*?[" else ch for ch in text)


def parameter_pattern_literal(text: str) -> str | None:
    if any(ch in text for ch in '"\\`$}\n'):
        return None
    return shell_pattern_literal(text)


def apply_rewrites(source: str, rewrites: list[Rewrite]) -> str:
    out: list[str] = []
    cursor = 0
    for rewrite in sorted(rewrites, key=lambda item: (item.start, item.end)):
        if rewrite.start < cursor:
            continue
        out.append(source[cursor : rewrite.start])
        out.append(rewrite.text)
        cursor = rewrite.end
    out.append(source[cursor:])
    return "".join(out)


def shell_optimizer_rewrites(source: str) -> list[Rewrite]:
    rewrites: list[Rewrite] = []
    rewrites.extend(command_substitution_rewrites(source))
    rewrites.extend(whole_line_rewrites(source))
    return rewrites


def command_substitution_rewrites(source: str) -> list[Rewrite]:
    rewrites: list[Rewrite] = []
    for start, end in command_substitution_spans(source):
        if is_comment_line_position(source, start):
            continue
        replacement = command_substitution_replacement(
            source[start:end],
            is_double_quoted_position(source, start),
            is_assignment_value_position(source, start),
        )
        if replacement is not None:
            text, reason = replacement
            rewrites.append(Rewrite(start, end, text, reason))
    return rewrites


def is_comment_line_position(source: str, pos: int) -> bool:
    line_start = source.rfind("\n", 0, pos) + 1
    return source[line_start:pos].lstrip().startswith("#")


def is_double_quoted_position(source: str, pos: int) -> bool:
    in_single = False
    in_double = False
    escaped = False
    for ch in source[source.rfind("\n", 0, pos) + 1 : pos]:
        if escaped:
            escaped = False
            continue
        if ch == "\\" and not in_single:
            escaped = True
            continue
        if ch == "'" and not in_double:
            in_single = not in_single
        elif ch == '"' and not in_single:
            in_double = not in_double
    return in_double


def is_assignment_value_position(source: str, pos: int) -> bool:
    line_prefix = source[source.rfind("\n", 0, pos) + 1 : pos]
    return re.fullmatch(rf"\s*{VAR}=", line_prefix) is not None


def shell_literal(
    text: str, in_double_quotes: bool, in_assignment_value: bool
) -> str | None:
    if re.fullmatch(BARE, text):
        return text
    if not in_assignment_value:
        return None
    if in_double_quotes:
        return None
    return shlex.quote(text)


def command_substitution_replacement(
    text: str, in_double_quotes: bool, in_assignment_value: bool
) -> tuple[str, str] | None:
    match = re.fullmatch(
        rf"\$\(echo\s+{DQ_VAR}\s+\|\s+cut\s+-c\s+([1-9][0-9]*)-([1-9][0-9]*)\)",
        text,
    )
    if match:
        var = match.group(1)
        start = int(match.group(2))
        end = int(match.group(3))
        if start <= end:
            return (
                f"${{{var}:{start - 1}:{end - start + 1}}}",
                "echo|cut -> parameter slice",
            )

    match = re.fullmatch(
        rf"\$\(expr\s+\$?({VAR}|[0-9]+)\s+([+*%-])\s+\$?({VAR}|[0-9]+)\)", text
    )
    if match:
        lhs, op, rhs = match.groups()
        return f"$(({lhs} {op} {rhs}))", "expr arithmetic -> shell arithmetic"

    match = re.fullmatch(rf"\$\(basename\s+{LITERAL_PATH}\)", text)
    if match:
        path = next(group for group in match.groups() if group is not None)
        literal = shell_literal(
            path.rsplit("/", 1)[1], in_double_quotes, in_assignment_value
        )
        if literal is not None:
            return literal, "literal basename -> literal"

    match = re.fullmatch(rf"\$\(dirname\s+{LITERAL_PATH}\)", text)
    if match:
        path = next(group for group in match.groups() if group is not None)
        literal = shell_literal(
            path.rsplit("/", 1)[0] or "/", in_double_quotes, in_assignment_value
        )
        if literal is not None:
            return literal, "literal dirname -> literal"

    return None


def whole_line_rewrites(source: str) -> list[Rewrite]:
    rewrites: list[Rewrite] = []
    offset = 0
    for line in source.splitlines(keepends=True):
        stripped = line.lstrip()
        if stripped.startswith("#"):
            offset += len(line)
            continue
        rewrites.extend(assignment_cat_rewrites(line, offset))
        rewrites.extend(grep_pipeline_rewrites(line, offset))
        offset += len(line)
    return rewrites


SINGLE_LINE_PREFIXES = ("/proc/", "/sys/")


def assignment_cat_rewrites(line: str, offset: int) -> list[Rewrite]:
    match = re.fullmatch(
        rf"(\s*)({VAR})=\$\(cat\s+({BARE})\)(\s*(?:#.*)?)(\n?)",
        line,
    )
    if not match:
        return []
    indent, var, path, suffix, newline = match.groups()
    if not any(path.startswith(prefix) for prefix in SINGLE_LINE_PREFIXES):
        return []
    text = f"{indent}IFS= read -r {var} < {path}{suffix}{newline}"
    return [
        Rewrite(offset, offset + len(line), text, "assignment cat -> read redirection")
    ]


def grep_pipeline_rewrites(line: str, offset: int) -> list[Rewrite]:
    grep_re = re.compile(
        rf"echo\s+{DQ_VAR}\s+\|\s+grep\s+-Fq\s+(?:'([^']*)'|\"([^\"$`\\]*)\"|({BARE}))"
    )
    rewrites: list[Rewrite] = []
    for match in grep_re.finditer(line):
        var = match.group(1)
        literal = next(group for group in match.groups()[1:] if group is not None)
        if literal == "":
            continue
        literal = parameter_pattern_literal(literal)
        if literal is None:
            continue
        text = f'[ "${{{var}#*{literal}}}" != "${var}" ]'
        rewrites.append(
            Rewrite(
                offset + match.start(),
                offset + match.end(),
                text,
                "grep -Fq pipeline -> parameter test",
            )
        )
    return rewrites


def optimize_shell(source: str) -> tuple[str, list[Rewrite]]:
    rewrites = shell_optimizer_rewrites(source)
    return apply_rewrites(source, rewrites), rewrites


def run_self_test() -> None:
    cases = {
        'x=$(echo "$var" | cut -c 2-4)\n': "x=${var:1:3}\n",
        'echo "$(basename /tmp/foo)"\n': 'echo "foo"\n',
        'dir=$(dirname "/tmp/foo")\n': "dir=/tmp\n",
        'name=$(basename "/tmp/foo bar")\n': "name='foo bar'\n",
        'dir=$(dirname "/tmp/foo bar/baz")\n': "dir='/tmp/foo bar'\n",
        'echo $(basename "/tmp/foo bar")\n': 'echo $(basename "/tmp/foo bar")\n',
        'cmd name=$(basename "/tmp/foo bar")\n': 'cmd name=$(basename "/tmp/foo bar")\n',
        'echo "$(basename "/tmp/foo bar")"\n': 'echo "$(basename "/tmp/foo bar")"\n',
        "n=$(expr $a + $b)\n": "n=$((a + b))\n",
        "n=$(expr 7 % 3)\n": "n=$((7 % 3))\n",
        "value=$(cat /proc/sys/kernel/pid_max)\n": "IFS= read -r value < /proc/sys/kernel/pid_max\n",
        'if echo "$mode" | grep -Fq "a*b"; then\n': 'if [ "${mode#*a\\*b}" != "$mode" ]; then\n',
        'if echo "$mode" | grep -Fq ""; then\n': 'if echo "$mode" | grep -Fq ""; then\n',
        'if echo "$mode" | grep -Fq "$"; then\n': 'if echo "$mode" | grep -Fq "$"; then\n',
        'if echo "$mode" | grep -Fq "}"; then\n': 'if echo "$mode" | grep -Fq "}"; then\n',
        'name=$(basename "$path")\n': 'name=$(basename "$path")\n',
        "# x=$(expr $a + $b)\n": "# x=$(expr $a + $b)\n",
    }
    for source, expected in cases.items():
        actual, _rewrites = optimize_shell(source)
        if actual != expected:
            raise SystemExit(
                "self-test failed\n"
                f"source:   {source!r}\nexpected: {expected!r}\nactual:   {actual!r}"
            )


def read_source(path: str | None) -> str:
    if path is None or path == "-":
        return sys.stdin.read()
    with open(path, "r", encoding="utf-8") as handle:
        return handle.read()


def write_source(path: str, source: str) -> None:
    with open(path, "w", encoding="utf-8") as handle:
        handle.write(source)


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "script", nargs="?", help="script to optimize; stdin when omitted"
    )
    parser.add_argument(
        "--in-place", action="store_true", help="rewrite script in place"
    )
    parser.add_argument(
        "--check",
        action="store_true",
        help="exit 1 if rewrites would change the script",
    )
    parser.add_argument(
        "--list", action="store_true", help="print rewrite spans and reasons to stderr"
    )
    parser.add_argument(
        "--self-test", action="store_true", help="run optimizer self-tests"
    )
    args = parser.parse_args(argv)

    if args.self_test:
        run_self_test()
        return 0

    if args.in_place and (not args.script or args.script == "-"):
        raise SystemExit("--in-place requires a file path")

    source = read_source(args.script)
    optimized, rewrites = optimize_shell(source)

    if args.list:
        for rewrite in rewrites:
            print(f"{rewrite.start}:{rewrite.end}: {rewrite.reason}", file=sys.stderr)

    if args.check:
        if optimized != source:
            name = args.script or "<stdin>"
            diff = difflib.unified_diff(
                source.splitlines(True),
                optimized.splitlines(True),
                fromfile=name,
                tofile=f"{name}.optimized",
            )
            sys.stderr.writelines(diff)
            return 1
        return 0

    if args.in_place:
        if optimized != source:
            write_source(args.script, optimized)
            mode = os.stat(args.script).st_mode
            os.chmod(args.script, mode)
    else:
        sys.stdout.write(optimized)
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
