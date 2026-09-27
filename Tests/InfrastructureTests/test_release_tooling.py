import importlib.util
import json
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest


PROJECT = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location("build_site", PROJECT / "Scripts/build_site.py")
build_site = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(build_site)

RELEASE = {
    "tagName": "v2.1.0",
    "publishedAt": "2026-09-27T12:00:00Z",
    "url": "https://github.com/mikkel32/ghost-process-sniper/releases/tag/v2.1.0",
    "assets": [
        {"name": "GhostProcessSniper-2.1.0.dmg.sha256", "size": 95, "url": "https://example.invalid/sha"},
        {"name": "GhostProcessSniper-2.1.0.dmg", "size": 13_532_345,
         "url": "https://github.com/mikkel32/ghost-process-sniper/releases/download/v2.1.0/GhostProcessSniper-2.1.0.dmg",
         "digest": "sha256:" + "ab" * 32},
    ],
}


class SiteBuildTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.out = Path(self.directory.name) / "site"

    def test_release_fills_download_version_size_and_checksum(self):
        build_site.build(self.out, RELEASE)
        page = (self.out / "index.html").read_text()
        self.assertIn(RELEASE["assets"][1]["url"], page)
        self.assertIn("Version 2.1.0 · 14 MB · Free · September 27, 2026", page)
        self.assertIn("ab" * 32, page)
        self.assertNotIn("{{", page)
        self.assertNotIn("<!--sha256-->", page)

    def test_without_a_release_the_page_links_to_the_release_list(self):
        build_site.build(self.out, {})
        page = (self.out / "index.html").read_text()
        self.assertIn('href="https://github.com/mikkel32/ghost-process-sniper/releases/latest"', page)
        self.assertNotIn('class="hash"', page)
        self.assertNotIn("{{", page)

    def test_every_image_the_page_uses_is_published(self):
        build_site.build(self.out, RELEASE)
        page = (self.out / "index.html").read_text()
        for name in ["favicon.png", "apple-touch-icon.png", "social-card.png", "assets/icon.png",
                     "assets/screenshot-overview.png", "assets/screenshot-security.png", "assets/installer.png"]:
            self.assertIn(name, page)
            self.assertTrue((self.out / name).is_file(), name)
        self.assertTrue((self.out / ".nojekyll").exists())

    def test_unknown_placeholder_fails_the_build(self):
        values = build_site.release_values({})
        with self.assertRaises(SystemExit):
            build_site.render("{{nope}}", values)


class ReleaseNotesTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.root = Path(self.directory.name)
        for name in ["Scripts/release_notes.sh", "Scripts/lib/project.sh"]:
            target = self.root / name
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(PROJECT / name, target)
        (self.root / "CHANGELOG.md").write_text(
            "# Changelog\n\n## [Unreleased]\n\n## [2.1.0] — 2026-09-27\n\nA summary line.\n\n"
            "### Sentinel\n- Watches things ([how](Docs/Sentinel.md), [web](https://example.com)).\n\n"
            "## [2.0.0] — 2026-09-26\n\n### Old\n- Older entry.\n")

    def notes(self, *arguments):
        return subprocess.run(["bash", str(self.root / "Scripts/release_notes.sh"), *arguments],
                              capture_output=True, text=True)

    def test_notes_carry_the_entry_steps_checksum_and_comparison(self):
        checksum = self.root / "image.sha256"
        checksum.write_text("cafe1234  GhostProcessSniper-2.1.0.dmg\n")
        result = self.notes("2.1.0", str(checksum))
        self.assertEqual(result.returncode, 0, result.stderr)
        notes = result.stdout
        self.assertIn("releases/download/v2.1.0/GhostProcessSniper-2.1.0.dmg", notes)
        self.assertIn("Open Anyway", notes)
        self.assertIn("A summary line.", notes)
        self.assertIn("### Sentinel", notes)
        self.assertNotIn("Older entry", notes)
        self.assertIn("SHA-256: `cafe1234`", notes)
        self.assertIn("gh attestation verify GhostProcessSniper-2.1.0.dmg", notes)
        self.assertIn("compare/v2.0.0...v2.1.0", notes)

    def test_relative_links_point_into_the_tag(self):
        notes = self.notes("2.1.0").stdout
        self.assertIn("(https://github.com/mikkel32/ghost-process-sniper/blob/v2.1.0/Docs/Sentinel.md)", notes)
        self.assertIn("(https://example.com)", notes)

    def test_missing_entry_fails(self):
        result = self.notes("9.9.9")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("no entry for 9.9.9", result.stderr)

    def test_oldest_release_has_no_comparison(self):
        notes = self.notes("2.0.0").stdout
        self.assertIn("Older entry.", notes)
        self.assertNotIn("compare/", notes)


class ReleaseWorkflowTests(unittest.TestCase):
    def test_release_workflow_attests_and_only_drafts(self):
        workflow = (PROJECT / ".github/workflows/release.yml").read_text()
        self.assertIn("actions/attest-build-provenance", workflow)
        self.assertIn("RADAR_REQUIRE_DMG_LAYOUT", workflow)
        self.assertIn("--draft", workflow)
        self.assertIn("Scripts/verify.sh", workflow)

    def test_changelog_has_an_entry_for_the_current_version(self):
        version = subprocess.run(["bash", "-c", "source Scripts/lib/project.sh && printf %s \"$RADAR_VERSION\""],
                                 cwd=PROJECT, capture_output=True, text=True).stdout
        self.assertIn(f"## [{version}]", (PROJECT / "CHANGELOG.md").read_text())


if __name__ == "__main__":
    unittest.main()
