"""Non-invasive structural tests for FlipSide source tree."""
from pathlib import Path
import re
import sqlite3
import unittest

ROOT = Path(__file__).resolve().parents[1]
PLUGIN = ROOT / "flipside.koplugin"


class SourceIntegrity(unittest.TestCase):
    def test_plugin_entrypoints_and_private_modules_exist(self):
        expected = (
            "main.lua", "_meta.lua", "flipside_db.lua",
            "flipside_cram_store.lua", "flipside_undo_recovery.lua",
            "flipside_learning_audit.lua", "flipside_flashcards.lua",
            "lib/sync/flipside_cram_merge.lua",
            "lib/sync/flipside_calendar_merge.lua",
            "lib/ui/flipside_pager_bounds.lua",
        )
        for filename in expected:
            with self.subTest(filename=filename):
                self.assertTrue((PLUGIN / filename).is_file())

    def test_tests_and_workflow_outside_installation(self):
        self.assertFalse((PLUGIN / "tests").exists())
        self.assertFalse((PLUGIN / ".github").exists())
        self.assertTrue((ROOT / "tests" / "run.lua").is_file())
        self.assertTrue((ROOT / ".github" / "workflows" / "flip-side-tests.yml").is_file())

    def test_no_personal_settings_or_sqlite_files_are_packaged(self):
        prohibited = re.compile(r"\.(sqlite3?|db)(?:-wal|-shm)?$", re.I)
        for path in PLUGIN.rglob("*"):
            if path.is_file():
                with self.subTest(file=path.name):
                    self.assertFalse(prohibited.search(path.name))
                    self.assertNotIn("settings", path.relative_to(PLUGIN).parts)


class SQLiteSchemaSmoke(unittest.TestCase):
    """SQLite tests use the literal CREATE schema from source in :memory:.

    They do NOT load real user databases or claim to test KOReader database I/O.
    """

    @classmethod
    def setUpClass(cls):
        source = (PLUGIN / "flipside_db.lua").read_text(encoding="utf-8")
        match = re.search(r"VOCABULARY_DB_SCHEMA\s*=\s*\[\[(.*?)\]\]", source, re.S)
        if match is None:
            raise AssertionError("Could not locate literal SQLite schema in flipside_db.lua")
        cls.schema = match.group(1)

    def setUp(self):
        self.db = sqlite3.connect(":memory:")
        self.db.executescript(self.schema)

    def tearDown(self):
        self.db.close()

    def test_expected_tables_and_indexes_exist(self):
        names = {row[0] for row in self.db.execute(
            "SELECT name FROM sqlite_master WHERE type IN ('table','index')")}
        for name in ("vocabulary", "title", "due_time_index", "title_name_index"):
            self.assertIn(name, names)

    def test_unique_words_and_review_fields(self):
        self.db.execute("INSERT INTO title (id,name) VALUES (1,'A book')")
        self.db.execute("""INSERT INTO vocabulary
            (word,title_id,create_time,due_time,review_count,streak_count)
            VALUES ('orchard',1,1760000000,1760000300,0,0)""")
        with self.assertRaises(sqlite3.IntegrityError):
            self.db.execute("""INSERT INTO vocabulary
                (word,title_id,create_time,due_time)
                VALUES ('orchard',1,1760000000,1760000300)""")
        self.db.execute("""UPDATE vocabulary SET review_count=1,
            streak_count=1,due_time=1760100000 WHERE word='orchard'""")
        item = self.db.execute("""SELECT review_count,streak_count,due_time
            FROM vocabulary WHERE word='orchard'""").fetchone()
        self.assertEqual(item, (1, 1, 1760100000))

    def test_rollback_keeps_previous_word_data(self):
        self.db.execute("INSERT INTO vocabulary (word, create_time, due_time) VALUES ('a',1,2)")
        self.db.commit()
        with self.assertRaises(RuntimeError):
            with self.db:
                self.db.execute("DELETE FROM vocabulary")
                raise RuntimeError("simulated failure")
        count = self.db.execute("SELECT count(*) FROM vocabulary").fetchone()[0]
        self.assertEqual(count, 1)


if __name__ == "__main__":
    unittest.main()
