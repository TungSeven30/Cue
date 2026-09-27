"""Guards for building Cue with the macOS 27 toolchain while supporting macOS 14.

Swift 6.4 changed two defaults that break a Command Line Tools build of Cue:
SwiftPM's build engine (see script/swiftpm.sh) and `@State`, which the macOS 27
SDK redeclares as an Xcode-only macro (see Sources/Views/ViewState.swift).
These tests keep a stray `swift build` or `@State` from reintroducing either
break, and keep the macOS 14 deployment target from drifting.
"""

from pathlib import Path
import re
import unittest

ROOT = Path(__file__).resolve().parents[1]

# A SwiftPM build or test *invocation*: at the start of a command, after a
# subshell `$(`, or after a workflow `run:`. Mentions inside messages such as
# `echo "run swift build first"` are not invocations.
SWIFTPM_INVOCATION = re.compile(r'(?:^|\$\(|\brun:|\bexec)\s*swift\s+(?:build|test)\b')
BARE_STATE = re.compile(r"@State(?![A-Za-z0-9_])")


def entry_point_files():
    yield from sorted((ROOT / "script").glob("*.sh"))
    yield from sorted((ROOT / "script" / "audit").glob("*.py"))
    yield from sorted((ROOT / ".github" / "workflows").glob("*.yml"))


class MacOS27ToolchainTests(unittest.TestCase):
    def test_swiftpm_wrapper_pins_native_build_system(self):
        wrapper = (ROOT / "script" / "swiftpm.sh").read_text()
        self.assertIn('exec swift "$subcommand" --build-system native "$@"', wrapper)

    def test_build_and_test_entry_points_use_the_wrapper(self):
        offenders = []
        for path in entry_point_files():
            if path.name == "swiftpm.sh":
                continue
            for number, line in enumerate(path.read_text().splitlines(), start=1):
                stripped = line.strip()
                if stripped.startswith("#"):
                    continue
                if SWIFTPM_INVOCATION.search(stripped):
                    offenders.append(f"{path.relative_to(ROOT)}:{number}: {stripped}")
        self.assertEqual(offenders, [], "call script/swiftpm.sh instead of swift build/test")

    def test_invocation_pattern_ignores_messages(self):
        self.assertTrue(SWIFTPM_INVOCATION.search('BIN_PATH="$(swift build --show-bin-path)"'))
        self.assertTrue(SWIFTPM_INVOCATION.search("run: swift build -c release"))
        self.assertTrue(SWIFTPM_INVOCATION.search('exec swift test "$@"'))
        self.assertFalse(SWIFTPM_INVOCATION.search("echo \"run 'swift build' first\""))

    def test_app_sources_use_view_state_not_the_state_macro(self):
        offenders = []
        for path in sorted((ROOT / "Sources").rglob("*.swift")):
            for number, line in enumerate(path.read_text().splitlines(), start=1):
                code = line.split("//", 1)[0]
                if BARE_STATE.search(code):
                    offenders.append(f"{path.relative_to(ROOT)}:{number}: {line.strip()}")
        self.assertEqual(offenders, [], "use @ViewState: bare @State needs Xcode on the macOS 27 SDK")
        self.assertFalse(BARE_STATE.search("@StateObject private var model"))

    def test_deployment_target_stays_macos_14(self):
        manifest = (ROOT / "Package.swift").read_text()
        self.assertIn(".macOS(.v14)", manifest)
        self.assertIn('MIN_SYSTEM_VERSION="14.0"', (ROOT / "script" / "build_and_run.sh").read_text())
        self.assertIn('"arm64-apple-macosx14.0"', (ROOT / "script" / "audit" / "build_harness.py").read_text())


if __name__ == "__main__":
    unittest.main()
