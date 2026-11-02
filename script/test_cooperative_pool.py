"""Keeps tests from parking Swift cooperative threads on child processes.

Swift Testing runs suites in parallel on the cooperative pool, which is only
as wide as the machine has cores (three on GitHub's macOS runners). A test
that blocks in `waitUntilExit` or `readDataToEndOfFile` holds a pool thread
for as long as its child runs; a few at once starve every other suite, so
timers stop firing and timing assertions elsewhere fail (BurnInProcessTests
measured 19 s for a 100 ms timeout this way). Tests run fixture processes
through `TestProcess.run` in Tests/CueTests/ProcessTestSupport.swift instead.
"""

from pathlib import Path
import re
import unittest

ROOT = Path(__file__).resolve().parents[1]
BLOCKING = re.compile(r"\.(?:waitUntilExit|readDataToEndOfFile)\(\)")


class CooperativePoolTests(unittest.TestCase):
    def test_tests_do_not_block_on_child_processes(self):
        offenders = []
        for path in sorted((ROOT / "Tests").rglob("*.swift")):
            for number, line in enumerate(path.read_text().splitlines(), start=1):
                code = line.split("//", 1)[0]
                if BLOCKING.search(code):
                    offenders.append(f"{path.relative_to(ROOT)}:{number}: {line.strip()}")
        self.assertEqual(offenders, [], "use TestProcess.run: blocking waits starve the parallel test pool")

    def test_pattern_ignores_prose(self):
        self.assertTrue(BLOCKING.search("process.waitUntilExit()"))
        self.assertTrue(BLOCKING.search("pipe.fileHandleForReading.readDataToEndOfFile()"))
        self.assertFalse(BLOCKING.search("blocks in `waitUntilExit` or `readDataToEndOfFile`"))


if __name__ == "__main__":
    unittest.main()
