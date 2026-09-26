import fcntl
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest


PROJECT = Path(__file__).resolve().parents[2]
LOCK = PROJECT / "Scripts/lib/with_lock.py"


class BuildLockTests(unittest.TestCase):
    def test_busy_lock_does_not_execute_command_and_releases_cleanly(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            path = root / "build.lock"
            marker = root / "executed"
            command = [sys.executable, str(LOCK), str(path), sys.executable, "-c",
                       "from pathlib import Path; import sys; Path(sys.argv[1]).touch()", str(marker)]
            with path.open("a") as held:
                fcntl.flock(held, fcntl.LOCK_EX | fcntl.LOCK_NB)
                blocked = subprocess.run(command, capture_output=True, text=True)
                self.assertEqual(blocked.returncode, 1)
                self.assertFalse(marker.exists())
            released = subprocess.run(command, capture_output=True, text=True)
            self.assertEqual(released.returncode, 0, released.stderr)
            self.assertTrue(marker.exists())


@unittest.skipUnless(sys.platform == "darwin", "Bundle verification uses macOS signing tools")
class BundleWorkflowTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory(prefix="radar bundle tests ")
        self.addCleanup(self.directory.cleanup)
        self.root = Path(self.directory.name)
        for name in ["Scripts/bundle-app.sh", "Scripts/lib/project.sh", "Scripts/lib/bundle_impl.sh",
                     "Scripts/lib/with_lock.py", "Scripts/dev.sh"]:
            target = self.root / name
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(PROJECT / name, target)
        self.app = self.root / "dist/Ghost Process Sniper.app"
        self.app.mkdir(parents=True)
        (self.app / "previous.marker").write_text("existing bundle")
        self.bin = self.root / "fake tools"
        self.bin.mkdir()
        self.product = self.root / "fixture build"
        self.product.mkdir()
        # Copy executable bytes, not macOS system-file flags, into the fixture.
        shutil.copyfile("/usr/bin/true", self.product / "GhostProcessSniper")
        (self.product / "GhostProcessSniper").chmod(0o755)
        self.staging = self.root / "staging tmp"
        self.staging.mkdir()
        self.env = dict(os.environ, CONFIGURATION="release",
                        PATH=str(self.bin) + os.pathsep + os.environ["PATH"],
                        RADAR_TEST_PRODUCT_DIR=str(self.product), TMPDIR=str(self.staging))
        self.tool("swift", '''#!/bin/sh
if [ "${RADAR_TEST_BUILD_FAIL:-0}" = 1 ]; then exit 17; fi
case " $* " in
  *" --show-bin-path "*) printf '%s\\n' "$RADAR_TEST_PRODUCT_DIR" ;;
esac
''')

    def tool(self, name, content):
        path = self.bin / name
        path.write_text(content)
        path.chmod(0o755)

    def run_bundle(self):
        return subprocess.run(["bash", str(self.root / "Scripts/bundle-app.sh")],
                              env=self.env, text=True, capture_output=True, timeout=30)

    def assert_no_staging_left(self):
        for directory in [self.root / "dist", self.staging]:
            self.assertEqual(list(directory.glob(".radar-stage.*")), [])

    def test_failed_build_preserves_previous_bundle(self):
        self.env["RADAR_TEST_BUILD_FAIL"] = "1"
        result = self.run_bundle()
        self.assertEqual(result.returncode, 17, result.stderr)
        self.assertTrue((self.app / "previous.marker").is_file())
        self.assert_no_staging_left()

    def test_success_installs_a_verified_bundle(self):
        result = self.run_bundle()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse((self.app / "previous.marker").exists())
        self.assertTrue((self.app / "Contents/MacOS/GhostProcessSniper").is_file())
        verified = subprocess.run(["/usr/bin/codesign", "--verify", "--strict", str(self.app)],
                                  capture_output=True, text=True)
        self.assertEqual(verified.returncode, 0, verified.stderr)
        self.assert_no_staging_left()

    def test_failed_replacement_rolls_back(self):
        self.tool("mv", '''#!/bin/sh
case "$1" in
  *"/.radar-stage."*"/Ghost Process Sniper.app") exit 23 ;;
esac
exec /bin/mv "$@"
''')
        result = self.run_bundle()
        self.assertEqual(result.returncode, 23, result.stderr)
        self.assertTrue((self.app / "previous.marker").is_file())
        self.assert_no_staging_left()

    def test_invalid_mode_has_no_build_or_process_side_effect(self):
        marker = self.root / "unexpected operation"
        self.env["RADAR_TEST_MARKER"] = str(marker)
        for name in ["swift", "pgrep", "pkill"]:
            self.tool(name, '#!/bin/sh\ntouch "$RADAR_TEST_MARKER"\n')
        result = subprocess.run(["bash", str(self.root / "Scripts/dev.sh"), "invalid-mode"],
                                env=self.env, text=True, capture_output=True)
        self.assertEqual(result.returncode, 2)
        self.assertFalse(marker.exists())
        self.assertTrue((self.app / "previous.marker").is_file())


if __name__ == "__main__":
    unittest.main()
