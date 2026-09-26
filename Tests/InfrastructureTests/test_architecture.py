import importlib.util
from pathlib import Path
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

    def write(self, relative, text):
        path = self.root / "Sources" / relative
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


if __name__ == "__main__":
    unittest.main()
