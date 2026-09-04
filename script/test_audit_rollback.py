import hashlib
import json
from pathlib import Path
import subprocess
import tempfile
import unittest

from audit.revert_item import rollback


class AuditRollbackTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="cue-rollback-tool-")
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.git("init", "-q")
        self.git("config", "user.name", "Cue test")
        self.git("config", "user.email", "cue-test@example.invalid")
        for name in ["Sources", "Tests"]:
            (self.root / name).mkdir()
            (self.root / name / "fixture.txt").write_text("fixed\n")
        self.commit()
        fixture = self.root / "Sources/fixture.txt"
        fixture.write_text("original\n")
        patch = self.git("diff", "--binary") + "\n"
        fixture.write_text("fixed\n")
        directory = self.root / "docs/audit/rollbacks"
        directory.mkdir(parents=True)
        (directory / "01.patch").write_text(patch)
        (directory / "manifest.json").write_text(json.dumps({
            "source_tree": self.git("rev-parse", "HEAD:Sources"),
            "test_tree": self.git("rev-parse", "HEAD:Tests"),
            "items": [{"item": 1, "title": "Fixture", "patch_sha256": hashlib.sha256(patch.encode()).hexdigest()}],
        }))
        self.commit()

    def git(self, *args):
        return subprocess.check_output(["git", *args], cwd=self.root, text=True, stderr=subprocess.DEVNULL).strip()

    def commit(self):
        self.git("add", ".")
        self.git("commit", "-qm", "Fixture")

    def test_check_does_not_change_files_or_index(self):
        self.assertEqual(rollback(self.root, 1), "Fixture")
        self.assertEqual(self.git("status", "--porcelain"), "")
        self.assertEqual((self.root / "Sources/fixture.txt").read_text(), "fixed\n")

    def test_apply_stages_only_selected_item_without_committing(self):
        head = self.git("rev-parse", "HEAD")
        rollback(self.root, 1, apply=True)
        self.assertEqual(self.git("rev-parse", "HEAD"), head)
        self.assertEqual(self.git("diff", "--cached", "--name-only"), "Sources/fixture.txt")
        self.assertEqual(self.git("diff", "--name-only"), "")
        self.assertEqual((self.root / "Tests/fixture.txt").read_text(), "fixed\n")

    def test_refuses_local_edits(self):
        (self.root / "Sources/fixture.txt").write_text("user edit\n")
        with self.assertRaisesRegex(ValueError, "clean"):
            rollback(self.root, 1, apply=True)
        self.assertEqual((self.root / "Sources/fixture.txt").read_text(), "user edit\n")

    def test_refuses_changed_source_history(self):
        (self.root / "Sources/fixture.txt").write_text("later fix\n")
        self.commit()
        with self.assertRaisesRegex(ValueError, "history has changed"):
            rollback(self.root, 1, apply=True)

    def test_refuses_modified_patch(self):
        patch = self.root / "docs/audit/rollbacks/01.patch"
        patch.write_text(patch.read_text() + "\n")
        self.commit()
        with self.assertRaisesRegex(ValueError, "checksum"):
            rollback(self.root, 1, apply=True)

    def test_refuses_unknown_item(self):
        with self.assertRaisesRegex(ValueError, "No rollback"):
            rollback(self.root, 2, apply=True)


if __name__ == "__main__":
    unittest.main()
