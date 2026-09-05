import json
from pathlib import Path
import tempfile
import unittest

from appcast_assets import referenced_assets, verify_available


class AppcastAssetTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="cue-appcast-assets-")
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.archive = self.root / "archive"
        self.archive.mkdir()
        self.appcast = self.root / "appcast.xml"

    def write_appcast(self, urls):
        enclosures = "".join(f'<enclosure url="{url}" />' for url in urls)
        self.appcast.write_text(f"<rss><channel><item>{enclosures}</item></channel></rss>")

    def test_lists_full_and_delta_artifacts_once(self):
        names = ["Cue-2.7.0.dmg", "Cue260-251.delta"]
        for name in names:
            (self.archive / name).write_bytes(b"artifact")
        prefix = "https://github.com/TungSeven30/cue-releases/releases/download/stable/"
        self.write_appcast([prefix + names[0], prefix + names[1], prefix + names[1]])
        self.assertEqual([path.name for path in referenced_assets(self.appcast, self.archive)], names)

    def test_rejects_missing_referenced_artifact(self):
        self.write_appcast([
            "https://github.com/TungSeven30/cue-releases/releases/download/stable/Cue404-251.delta"
        ])
        with self.assertRaisesRegex(ValueError, "missing local artifact"):
            referenced_assets(self.appcast, self.archive)

    def test_rejects_unexpected_host_and_encoded_subpath(self):
        for url in [
            "https://example.com/Cue-2.7.0.dmg",
            "https://github.com/TungSeven30/cue-releases/releases/download/stable/sub%2FCue-2.7.0.dmg",
        ]:
            self.write_appcast([url])
            with self.assertRaisesRegex(ValueError, "unexpected|unsafe"):
                referenced_assets(self.appcast, self.archive)

    def test_verifies_every_appcast_asset_is_on_the_release(self):
        assets = [self.archive / "Cue-2.7.0.dmg", self.archive / "Cue260-251.delta"]
        release = self.root / "release.json"
        release.write_text(json.dumps({"assets": [{"name": assets[0].name}]}))
        with self.assertRaisesRegex(ValueError, "Cue260-251.delta"):
            verify_available(assets, release)
        release.write_text(json.dumps({"assets": [{"name": asset.name} for asset in assets]}))
        verify_available(assets, release)


if __name__ == "__main__":
    unittest.main()
