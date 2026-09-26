#!/usr/bin/env python3
"""Check source ownership and prevent new oversized catch-all files."""

from __future__ import annotations

import argparse
import json
from pathlib import Path
import re
import subprocess
import sys


IMPORT = re.compile(
    r"^\s*(?:@\w+(?:\([^)]*\))?\s+)*"
    r"(?:(?:public|internal|package|private|fileprivate)\s+)?import\s+"
    r"(?:(?:typealias|struct|class|enum|protocol|let|var|func)\s+)?(\w+)",
    re.MULTILINE,
)


def check(root: Path, policy: dict) -> list[str]:
    problems: list[str] = []
    sources = root / "Sources"
    targets = policy["targets"]
    budgets = policy.get("legacy_line_budgets", {})
    maximum = policy["default_max_lines"]
    files = sorted(sources.rglob("*.swift"))
    if not files:
        return ["No Swift sources found; check the project root."]

    for file in files:
        path = file.relative_to(sources)
        key = path.as_posix()
        target = path.parts[0]
        allowed = targets.get(target, [])
        if len(path.parts) < 3 or not any(
            path.parent.as_posix() == f"{target}/{folder}"
            or path.parent.as_posix().startswith(f"{target}/{folder}/")
            for folder in allowed
        ):
            problems.append(f"{key}: place this source in a declared responsibility folder.")

        text = file.read_text(encoding="utf-8")
        lines = len(text.splitlines())
        limit = budgets.get(key, maximum)
        if lines > limit:
            problems.append(f"{key}: {lines} lines exceeds its {limit}-line budget; extract a responsibility.")

        imports = set(IMPORT.findall(text))
        if target == "GhostProcessSniperCore":
            forbidden = imports & {"SwiftUI", "GhostProcessSniper"}
            if forbidden:
                problems.append(f"{key}: core must not import {', '.join(sorted(forbidden))}.")
        if "SQLite3" in imports or re.search(r"\bsqlite3_[a-zA-Z_]+\b", text):
            if not key.startswith("GhostProcessSniperCore/Persistence/"):
                problems.append(f"{key}: SQLite access belongs to core/Persistence.")

    problems += ratchet(sources, budgets, maximum)
    problems += check_test_roots(root, policy.get("test_roots", {}), maximum)
    return problems


def line_count(path: Path) -> int:
    return len(path.read_text(encoding="utf-8").splitlines())


def ratchet(base: Path, budgets: dict, maximum: int) -> list[str]:
    """Legacy budgets may only shrink: each must equal its file's length, so any
    growth has to raise the budget visibly in architecture.json."""
    problems: list[str] = []
    for key, budget in budgets.items():
        file = base / key
        if not file.is_file():
            problems.append(f"{key}: remove or update this stale legacy budget.")
            continue
        lines = line_count(file)
        if lines < budget:
            if lines <= maximum:
                problems.append(f"{key}: now {lines} lines; remove the entry from its legacy budgets.")
            else:
                problems.append(f"{key}: lower its legacy budget to {lines}.")
    return problems


def check_test_roots(root: Path, section: dict, maximum: int) -> list[str]:
    """Tests and checks get line budgets only; they have no folder rules."""
    problems: list[str] = []
    budgets = section.get("legacy_line_budgets", {})
    for folder in section.get("roots", []):
        for file in sorted((root / folder).rglob("*.swift")):
            key = file.relative_to(root).as_posix()
            lines = line_count(file)
            limit = budgets.get(key, maximum)
            if lines > limit:
                problems.append(f"{key}: {lines} lines exceeds its {limit}-line budget; split the file.")
    return problems + ratchet(root, budgets, maximum)


def budget_increases(policy: dict, base: dict, ref: str) -> list[str]:
    """Compares every budget with the one at `ref`; a new legacy entry counts as an
    increase from the default. Test budgets are compared once `ref` has them."""
    problems: list[str] = []
    base_maximum = base.get("default_max_lines", policy["default_max_lines"])
    if policy["default_max_lines"] > base_maximum:
        problems.append(f"default_max_lines: raised above {base_maximum} on {ref}.")
    sections = [(policy.get("legacy_line_budgets", {}), base.get("legacy_line_budgets", {}))]
    if "test_roots" in base:
        sections.append((policy.get("test_roots", {}).get("legacy_line_budgets", {}),
                         base["test_roots"].get("legacy_line_budgets", {})))
    for current, previous in sections:
        for key, budget in current.items():
            limit = previous.get(key, base_maximum)
            if budget > limit:
                problems.append(f"{key}: legacy budget {budget} is above {limit} on {ref}; budgets may only shrink.")
    return problems


def base_policy(root: Path, ref: str) -> dict | None:
    """The policy at `ref`, or None when git or the ref is unavailable."""
    try:
        shown = subprocess.run(["git", "-C", str(root), "show", f"{ref}:Config/architecture.json"],
                               capture_output=True, text=True, check=False)
    except OSError:
        return None
    if shown.returncode != 0:
        return None
    try:
        return json.loads(shown.stdout)
    except ValueError:
        return None


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", type=Path, default=Path(__file__).resolve().parent.parent)
    parser.add_argument("--base", metavar="GIT_REF",
                        help="also fail when a budget is higher than in this ref; skipped if it is unavailable")
    args = parser.parse_args()
    try:
        policy = json.loads((args.root / "Config/architecture.json").read_text())
        problems = check(args.root, policy)
        if args.base and (base := base_policy(args.root, args.base)) is not None:
            problems += budget_increases(policy, base, args.base)
    except (OSError, ValueError, KeyError, TypeError) as error:
        print(f"Architecture configuration error: {error}", file=sys.stderr)
        return 2
    if problems:
        print("\n".join(problems), file=sys.stderr)
        return 1
    print("Architecture checks passed: source ownership, core/UI boundary, SQLite boundary, and file budgets"
          " (legacy budgets match their files; tests and checks included).")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
