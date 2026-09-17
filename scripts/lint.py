#!/usr/bin/env python3
"""Lint the lines a change touches, not the whole tree.

The tree carries style findings from before there was a linter, and a gate that fails on lines
nobody touched is a gate people turn off. Only changed lines are reported here; a finding on a line
nobody touched is left to the day that line changes.

Swift goes through the toolchain's swift-format, and only its rule findings count. The engine also
reports where it would re-indent or re-wrap code it read (Indentation, AddLines, RemoveLine); that
is a matter of house style here, so those are skipped. TypeScript under mcp/ goes through Biome,
with the configuration that directory already ships.

Usage:
    scripts/lint.py --staged     the files staged for this commit (what the pre-commit hook runs)
    scripts/lint.py PATH...      the named files, whole
"""

from __future__ import annotations

import re
import subprocess
import sys
from pathlib import Path

root = Path(__file__).resolve().parent.parent

# The formatting engine's own findings, which describe where it would lay code out differently
# rather than a rule the repo broke.
engine_findings = {"Indentation", "AddLines", "RemoveLine"}

finding = re.compile(
    r"^(?P<file>.+?):(?P<line>[0-9]+):(?P<column>[0-9]+): warning: \[(?P<tag>[^\]]+)\] (?P<text>.*)$"
)
hunk = re.compile(r"^@@ -[0-9]+(?:,[0-9]+)? \+([0-9]+)(?:,([0-9]+))? @@", re.MULTILINE)


def run_result(command: list[str], cwd: Path = root) -> subprocess.CompletedProcess[str]:
    return subprocess.run(command, cwd=cwd, capture_output=True, text=True)


def run(command: list[str], cwd: Path = root) -> str:
    result = run_result(command, cwd)
    return result.stdout + result.stderr


def staged_files() -> list[Path]:
    listed = run(["git", "diff", "--cached", "--name-only", "--diff-filter=ACMR"]).split()
    return [root / name for name in listed]


def changed_lines(path: Path) -> set[int]:
    diff = run(["git", "diff", "--cached", "-U0", "--", str(path.relative_to(root))])
    lines: set[int] = set()
    for match in hunk.finditer(diff):
        start = int(match.group(1))
        count = int(match.group(2) or "1")
        lines.update(range(start, start + count))
    return lines


def swift_findings(paths: list[Path], changes: dict[Path, set[int]]) -> list[str]:
    output = run(["swift", "format", "lint", *[str(path) for path in paths]])
    found = []
    for row in output.splitlines():
        match = finding.match(row)
        if match is None or match.group("tag") in engine_findings:
            continue
        path = Path(match.group("file"))
        if changes and int(match.group("line")) not in changes.get(path, set()):
            continue
        found.append(
            str(path.relative_to(root))
            + ":"
            + match.group("line")
            + ": ["
            + match.group("tag")
            + "] "
            + match.group("text")
        )
    return found


def mcp_findings(paths: list[Path]) -> list[str]:
    biome = root / "mcp" / "node_modules" / ".bin" / "biome"
    command = [str(biome)] if biome.exists() else ["bunx", "biome"]
    relative = [str(path.relative_to(root / "mcp")) for path in paths]
    result = run_result([*command, "check", *relative], cwd=root / "mcp")
    if result.returncode == 0:
        return []
    return [row for row in (result.stdout + result.stderr).splitlines() if row.strip()]


def main() -> int:
    arguments = sys.argv[1:]
    named = [argument for argument in arguments if not argument.startswith("--")]
    staged = "--staged" in arguments or not named

    if staged:
        paths = staged_files()
        changes = {path.resolve(): changed_lines(path) for path in paths}
    else:
        paths = [Path(argument).resolve() for argument in named]
        changes = {}

    swift = [path for path in paths if path.suffix == ".swift"]
    mcp = [
        path
        for path in paths
        if path.suffix in {".ts", ".js", ".mjs"} and "mcp/" in str(path)
    ]

    found: list[str] = []
    if swift:
        found += swift_findings(swift, changes)
    if mcp:
        found += mcp_findings(mcp)

    for row in found:
        print(row)
    if found:
        print()
        where = "on changed lines" if staged else "in the files named"
        print(str(len(found)) + " finding(s) " + where + ".")
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
