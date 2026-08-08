import unittest

import sync_backend_script


class BackendScriptSyncTests(unittest.TestCase):
    def test_standalone_matches_embedded_source(self):
        self.assertEqual(
            sync_backend_script.STANDALONE.read_text(encoding="utf-8"),
            sync_backend_script.embedded_source(),
        )


if __name__ == "__main__":
    unittest.main()
