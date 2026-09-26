import importlib.util
import json
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest


SCRIPT = Path(__file__).resolve().parents[2] / "Scripts/check_architecture.py"
SPEC = importlib.util.spec_from_file_location("architecture", SCRIPT)
architecture = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(architecture)


class ArchitectureTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.root = Path(self.directory.name)
        self.policy = {
            "targets": {"GhostProcessSniperCore": ["Domain", "Persistence"], "GhostProcessSniper": ["Features"]},
            "default_max_lines": 10,
            "legacy_line_budgets": {},
        }

    def write(self, relative, text, base="Sources"):
        path = self.root / base / relative if base else self.root / relative
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(text)

    def test_empty_checkout_fails(self):
        self.assertTrue(architecture.check(self.root, self.policy))

    def test_owned_core_and_ui_files_pass(self):
        self.write("GhostProcessSniperCore/Domain/Model.swift", "import Foundation\n")
        self.write("GhostProcessSniper/Features/View.swift", "import SwiftUI\nimport GhostProcessSniperCore\n")
        self.assertEqual(architecture.check(self.root, self.policy), [])

    def test_root_dumping_ground_fails(self):
        self.write("GhostProcessSniperCore/Model.swift", "import Foundation\n")
        self.assertTrue(architecture.check(self.root, self.policy))

    def test_ui_dependency_in_core_fails(self):
        self.write("GhostProcessSniperCore/Domain/Model.swift", "import SwiftUI\n")
        self.assertTrue(architecture.check(self.root, self.policy))

    def test_database_calls_outside_persistence_fail(self):
        self.write("GhostProcessSniperCore/Domain/Model.swift", "let value = sqlite3_step(statement)\n")
        self.assertTrue(architecture.check(self.root, self.policy))

    def test_selective_ui_import_in_core_fails(self):
        self.write("GhostProcessSniperCore/Domain/Model.swift", "import struct SwiftUI.Color\n")
        self.assertTrue(architecture.check(self.root, self.policy))

    def test_access_controlled_ui_import_in_core_fails(self):
        self.write("GhostProcessSniperCore/Domain/Model.swift", "public import SwiftUI\n")
        self.assertTrue(architecture.check(self.root, self.policy))

    def test_database_inside_persistence_passes(self):
        self.write("GhostProcessSniperCore/Persistence/Store.swift", "import SQLite3\n")
        self.assertEqual(architecture.check(self.root, self.policy), [])

    def test_oversized_file_fails(self):
        self.write("GhostProcessSniperCore/Domain/Model.swift", "// line\n" * 11)
        self.assertTrue(architecture.check(self.root, self.policy))

    def test_stale_budget_fails(self):
        self.write("GhostProcessSniperCore/Domain/Model.swift", "import Foundation\n")
        self.policy["legacy_line_budgets"]["GhostProcessSniperCore/Domain/Deleted.swift"] = 20
        self.assertTrue(architecture.check(self.root, self.policy))

    def test_legacy_budget_with_headroom_must_be_lowered(self):
        self.write("GhostProcessSniperCore/Domain/Model.swift", "// line\n" * 14)
        self.policy["legacy_line_budgets"]["GhostProcessSniperCore/Domain/Model.swift"] = 16
        problems = architecture.check(self.root, self.policy)
        self.assertEqual(problems, ["GhostProcessSniperCore/Domain/Model.swift: lower its legacy budget to 14."])

    def test_legacy_budget_under_default_must_be_removed(self):
        self.write("GhostProcessSniperCore/Domain/Model.swift", "// line\n" * 9)
        self.policy["legacy_line_budgets"]["GhostProcessSniperCore/Domain/Model.swift"] = 16
        problems = architecture.check(self.root, self.policy)
        self.assertEqual(len(problems), 1)
        self.assertIn("remove the entry", problems[0])

    def test_exact_legacy_budget_passes(self):
        self.write("GhostProcessSniperCore/Domain/Model.swift", "// line\n" * 14)
        self.policy["legacy_line_budgets"]["GhostProcessSniperCore/Domain/Model.swift"] = 14
        self.assertEqual(architecture.check(self.root, self.policy), [])

    def test_test_file_over_budget_fails_without_folder_rules(self):
        self.write("GhostProcessSniperCore/Domain/Model.swift", "import Foundation\n")
        self.write("Tests/CoreTests/Deep/Nested/ModelTests.swift", "// line\n" * 11, base=None)
        self.write("Checks/CoreChecks/main.swift", "// line\n" * 12, base=None)
        self.policy["test_roots"] = {
            "roots": ["Tests/CoreTests", "Checks/CoreChecks"],
            "legacy_line_budgets": {"Checks/CoreChecks/main.swift": 12},
        }
        problems = architecture.check(self.root, self.policy)
        self.assertEqual(len(problems), 1)
        self.assertTrue(problems[0].startswith("Tests/CoreTests/Deep/Nested/ModelTests.swift: 11 lines"))

    def test_stale_and_loose_test_budgets_fail(self):
        self.write("GhostProcessSniperCore/Domain/Model.swift", "import Foundation\n")
        self.write("Checks/CoreChecks/main.swift", "// line\n" * 12, base=None)
        self.policy["test_roots"] = {
            "roots": ["Checks/CoreChecks"],
            "legacy_line_budgets": {"Checks/CoreChecks/main.swift": 20, "Checks/CoreChecks/Gone.swift": 30},
        }
        problems = architecture.check(self.root, self.policy)
        self.assertIn("Checks/CoreChecks/main.swift: lower its legacy budget to 12.", problems)
        self.assertIn("Checks/CoreChecks/Gone.swift: remove or update this stale legacy budget.", problems)

    def test_base_ref_detects_budget_increases(self):
        if shutil.which("git") is None:
            self.skipTest("git is not installed")
        self.write("GhostProcessSniperCore/Domain/Model.swift", "import Foundation\n")
        self.policy["legacy_line_budgets"] = {"GhostProcessSniperCore/Domain/Big.swift": 20}
        self.policy["test_roots"] = {"roots": [], "legacy_line_budgets": {"Checks/main.swift": 30}}
        config = self.root / "Config/architecture.json"
        config.parent.mkdir(parents=True)
        config.write_text(json.dumps(self.policy))
        git = ["git", "-C", str(self.root), "-c", "user.name=Test", "-c", "user.email=test@example.com",
               "-c", "commit.gpgsign=false"]
        subprocess.run(git + ["init", "-q"], check=True)
        subprocess.run(git + ["add", "-A"], check=True)
        subprocess.run(git + ["commit", "-q", "-m", "base"], check=True)

        raised = json.loads(json.dumps(self.policy))
        raised["legacy_line_budgets"]["GhostProcessSniperCore/Domain/Big.swift"] = 25
        raised["legacy_line_budgets"]["GhostProcessSniperCore/Domain/New.swift"] = 15
        raised["test_roots"]["legacy_line_budgets"]["Checks/main.swift"] = 29
        base = architecture.base_policy(self.root, "HEAD")
        problems = architecture.budget_increases(raised, base, "HEAD")
        self.assertEqual(len(problems), 2)
        self.assertTrue(problems[0].startswith("GhostProcessSniperCore/Domain/Big.swift: legacy budget 25 is above 20"))
        self.assertTrue(problems[1].startswith("GhostProcessSniperCore/Domain/New.swift: legacy budget 15 is above 10"))
        self.assertEqual(architecture.budget_increases(self.policy, base, "HEAD"), [])
        self.assertIsNone(architecture.base_policy(self.root, "no-such-ref"))


if __name__ == "__main__":
    unittest.main()
