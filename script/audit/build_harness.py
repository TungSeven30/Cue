#!/usr/bin/env python3
"""Build a local-only app from existing debug Cue objects; never installs it.
Run ./script/run_tests.sh first. Usage: build_harness.py OUTPUT_ROOT MEDIA_PATH
"""
import json
import pathlib
import plistlib
import shutil
import subprocess
import sys

repository = pathlib.Path(__file__).resolve().parents[2]
root = pathlib.Path(sys.argv[1]).resolve()
media = pathlib.Path(sys.argv[2]).resolve()
if not media.is_file():
    raise SystemExit("Media fixture does not exist")
root.mkdir(parents=True, exist_ok=True)
(root / "home").mkdir(exist_ok=True)
build = (repository / ".build/debug").resolve()
app = root / "Cue Audit.app"
contents = app / "Contents"
for part in ("MacOS", "Resources", "Frameworks"):
    (contents / part).mkdir(parents=True, exist_ok=True)
objects = (build / "Cue.product/Objects.LinkFileList").read_text().splitlines()
# SwiftPM names Cue's entry point Cue_main. The harness supplies its own
# main without the production linker's Cue_main-to-main alias; retaining
# CueApp.swift.o also retains the shared OpenFileRequests implementation.
linkfile = root / "objects.txt"
linkfile.write_text("\n".join(objects) + "\n")
subprocess.run([
    "swiftc", str(repository / "script/audit/CueAuditHarness.swift"), "-parse-as-library",
    "-module-name", "CueAuditHarness", "-swift-version", "6", "-target", "arm64-apple-macosx14.0",
    "-I", str(build / "Modules"), "-F", str(build), "-framework", "Sparkle", "-framework", "Accelerate", "-lc++",
    "-Xcc", "-fmodule-map-file=" + str(build / "whisper.build/module.modulemap"),
    "-Xcc", "-I" + str(repository / ".build/checkouts/whisper.cpp/spm-headers"),
    "-Xcc", "-Wno-incomplete-umbrella",
    "-module-cache-path", str(root / "module-cache"),
    "@" + str(linkfile), "-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks",
    "-o", str(contents / "MacOS/CueAuditHarness"),
], check=True)
framework = contents / "Frameworks/Sparkle.framework"
if framework.exists():
    shutil.rmtree(framework)
shutil.copytree(build / "Sparkle.framework", framework, symlinks=True)
with (contents / "Resources/Fixture.plist").open("wb") as output:
    plistlib.dump({"root": str(root), "media": str(media)}, output)
with (contents / "Info.plist").open("wb") as output:
    plistlib.dump({
        "CFBundleExecutable": "CueAuditHarness", "CFBundleIdentifier": "org.codex.CueAuditHarness",
        "CFBundleName": "Cue Audit", "CFBundlePackageType": "APPL", "CFBundleVersion": "1",
        "LSMinimumSystemVersion": "14.0", "NSHighResolutionCapable": True, "NSPrincipalClass": "NSApplication",
        "LSEnvironment": {"CFFIXED_USER_HOME": str(root / "home")},
    }, output)
subprocess.run(["codesign", "--force", "--deep", "--sign", "-", str(app)], check=True)
print(app)
