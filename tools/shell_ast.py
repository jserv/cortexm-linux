"""Small shell parser subset used by optimize-shell.py.

This is not a full shell parser.  It provides the small interface that the
optimizer needs today: parse a script and expose command-substitution nodes
with source spans.  Keeping this in tools/ makes optimizer behavior
reproducible on build hosts without installing Python packages.
"""

from __future__ import annotations

from dataclasses import dataclass, field


@dataclass
class Node:
    kind: str
    pos: tuple[int, int]
    parts: list["Node"] = field(default_factory=list)


def parse(source: str) -> list[Node]:
    return [Node("script", (0, len(source)), command_substitutions(source))]


def command_substitutions(source: str) -> list[Node]:
    nodes: list[Node] = []
    i = 0
    quote: str | None = None
    while i < len(source):
        ch = source[i]
        if quote == "'":
            if ch == "'":
                quote = None
            i += 1
            continue
        if ch == "\\" and quote != "'":
            i += 2  # skip escaped char (handles \$( and \) )
            continue
        if quote == '"' and ch == '"':
            quote = None
            i += 1
            continue
        if quote is None and ch in "'\"":
            quote = ch
            i += 1
            continue
        if source.startswith("$(", i):
            end = find_matching_paren(source, i + 2)
            if end is not None:
                nodes.append(Node("commandsubstitution", (i, end + 1)))
                i = end + 1
                continue
        i += 1
    return nodes


def find_matching_paren(source: str, start: int) -> int | None:
    depth = 1
    quote: str | None = None
    i = start
    while i < len(source):
        ch = source[i]
        if quote:
            if ch == "\\" and i + 1 < len(source):
                i += 2
                continue
            if ch == quote:
                quote = None
            i += 1
            continue
        if ch == "\\" and i + 1 < len(source):
            i += 2  # skip \) and other escaped chars outside quotes
            continue
        if ch in "'\"":
            quote = ch
        elif source.startswith("$(", i):
            depth += 1
            i += 1
        elif ch == ")":
            depth -= 1
            if depth == 0:
                return i
        i += 1
    return None
