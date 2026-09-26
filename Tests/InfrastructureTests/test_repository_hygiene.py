import json
from pathlib import Path
import unittest


PROJECT = Path(__file__).resolve().parents[2]

# Pointers to UI that no longer exists: the Engine screen (now Settings ›
# Diagnostics), Precision targets, the old force switch and the ⌘6 shortcut.
STALE_UI_REFERENCES = [
    "Engine →",
    "| **Engine**",
    "Precision targets",
    "⌘6",
    "Report anything that refuses to stop**",
]


class RepositoryHygieneTests(unittest.TestCase):
    def test_every_architecture_folder_exists(self):
        policy = json.loads((PROJECT / "Config/architecture.json").read_text())
        missing = [f"{target}/{folder}"
                   for target, folders in policy["targets"].items()
                   for folder in folders
                   if not (PROJECT / "Sources" / target / folder).is_dir()]
        self.assertEqual(missing, [], "drop allowlisted folders that no longer exist")

    def test_docs_do_not_point_to_removed_ui(self):
        documents = [PROJECT / name for name in ["README.md", "CONTRIBUTING.md", "CHANGELOG.md"]]
        documents += sorted((PROJECT / "Docs").glob("**/*.md"))
        problems = []
        for document in documents:
            for number, line in enumerate(document.read_text().splitlines(), start=1):
                problems += [f"{document.relative_to(PROJECT)}:{number}: {needle}"
                             for needle in STALE_UI_REFERENCES if needle in line]
        self.assertEqual(problems, [])


if __name__ == "__main__":
    unittest.main()
