#!/usr/bin/env python3
"""Measure fresh synthetic harness processes; does not measure first pixels.
Usage: measure_harness.py OUTPUT_ROOT [TRIALS=10]
Only generated fixture history under the validated temporary root is reset.
"""
import json
import math
import pathlib
import plistlib
import shutil
import statistics
import subprocess
import sys
import tempfile

root = pathlib.Path(sys.argv[1]).resolve()
trials = int(sys.argv[2]) if len(sys.argv) > 2 else 10
if not 1 <= trials <= 100:
    raise SystemExit("Trial count must be between 1 and 100")
if not any(root.is_relative_to(p.resolve()) for p in [pathlib.Path('/private/tmp'), pathlib.Path(tempfile.gettempdir())]):
    raise SystemExit("The audit root must be inside a temporary directory")
app = root / "Cue Audit.app"
with (app / "Contents/Resources/Fixture.plist").open("rb") as source:
    fixture = plistlib.load(source)
if pathlib.Path(fixture['root']).resolve() != root:
    raise SystemExit("Fixture root does not match the requested audit root")
records = []
for trial in range(trials):
    history = root / "history"
    if history.exists():
        shutil.rmtree(history)
    metrics = root / "metrics.json"
    metrics.unlink(missing_ok=True)
    with (root / f"trial-{trial + 1:02}.log").open("w") as output:
        subprocess.run([str(app / "Contents/MacOS/CueAuditHarness"), "--measure"],
                       stdout=output, stderr=subprocess.STDOUT, timeout=45, check=True)
    record = json.loads(metrics.read_text())
    if not 18 <= record['mediaTimeSeconds'] <= 24:
        raise SystemExit("Playback did not advance as expected; refusing an invalid baseline")
    if record['overlayModelReadyMs'] is None:
        raise SystemExit("No subtitle overlay was prepared")
    records.append(record)
    (root / "trials.json").write_text(json.dumps(records, indent=2))
    print(f"Completed {trial + 1}/{trials}: view={record['viewAppearedMs']:.2f} ms, overlay model={record['overlayModelReadyMs']:.2f} ms", flush=True)


def distribution(values):
    if not all(math.isfinite(v) and v >= 0 for v in values):
        raise SystemExit("A measurement was unavailable or invalid")
    return {'count': len(values), 'median': statistics.median(values), 'mean': statistics.mean(values), 'min': min(values), 'max': max(values)}

summary = {
    'scope': 'Debug Cue objects, synthetic workspace, new process, warm filesystem. Markers begin at SwiftUI App initialization; not cold launch or first rendered pixels.',
    'trials': trials,
    'viewAppearedMs': distribution([r['viewAppearedMs'] for r in records]),
    'overlayModelReadyMs': distribution([r['overlayModelReadyMs'] for r in records]),
    'idleFootprintMiB': distribution([v for r in records for v in r['idleFootprintMiB']]),
    'playbackFootprintMiB': distribution([s['footprintMiB'] for r in records for s in r['playbackSamples']]),
    'playbackCPUPercent': distribution([s['cpuPercent'] for r in records for s in r['playbackSamples']]),
    'displayMinimumRefreshInterval': records[-1]['minimumRefreshInterval'],
    'displayMaximumRefreshInterval': records[-1]['maximumRefreshInterval'],
    'droppedFrames60Hz': None, 'droppedFrames120Hz': None,
}
(root / 'summary.json').write_text(json.dumps(summary, indent=2))
print(json.dumps(summary, indent=2))
