#!/usr/bin/env python3
"""Check source ownership and prevent new oversized catch-all files."""

import argparse
import json
from pathlib import Path
import re
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

    for key in budgets:
        if not (sources / key).is_file():
            problems.append(f"{key}: remove or update this stale legacy budget.")
    return problems


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", type=Path, default=Path(__file__).resolve().parent.parent)
    args = parser.parse_args()
    try:
        policy = json.loads((args.root / "Config/architecture.json").read_text())
        problems = check(args.root, policy)
    except (OSError, ValueError, KeyError, TypeError) as error:
        print(f"Architecture configuration error: {error}", file=sys.stderr)
        return 2
    if problems:
        print("\n".join(problems), file=sys.stderr)
        return 1
    print("Architecture checks passed: source ownership, core/UI boundary, SQLite boundary, and file budgets.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
