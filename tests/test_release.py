"""Prove release packaging never bundles tests or personal data."""
from pathlib import Path
import unittest
import zipfile

ROOT = Path(__file__).resolve().parents[1]
ZIP = ROOT / "dist" / "FlipSide-1.0.0-rc.1.zip"
PLUGIN = ROOT / "flipside.koplugin"


class ReleaseZip(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        if not ZIP.is_file():
            raise unittest.SkipTest("Run python3 scripts/build_release.py first")

    def test_all_entries_are_plugin_files_only(self):
        with zipfile.ZipFile(ZIP) as archive:
            entries = archive.namelist()
            self.assertTrue(entries)
            self.assertEqual(len(entries), len(set(entries)))
            self.assertIsNone(archive.testzip())
            self.assertTrue(all(s.startswith("flipside.koplugin/") for s in entries))
            for path in entries:
                self.assertNotIn("../", path)
                self.assertNotIn("/tests/", path)
                self.assertNotIn("/.github/", path)
                self.assertFalse(path.endswith((".db", ".sqlite3", ".old")))

    def test_release_bytes_identical_to_plugin_sources(self):
        with zipfile.ZipFile(ZIP) as archive:
            entries = set(archive.namelist())
            files = {p.relative_to(ROOT).as_posix(): p
                     for p in PLUGIN.rglob("*") if p.is_file()}
            self.assertEqual(entries, set(files))
            for arcname, path in files.items():
                with self.subTest(file=arcname):
                    self.assertEqual(archive.read(arcname), path.read_bytes())


if __name__ == "__main__":
    unittest.main()
