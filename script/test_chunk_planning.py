#!/usr/bin/env python3
"""Verifies plan_speech_chunks against synthetic audio with known silences.
Run: python3 script/test_chunk_planning.py  (exit 0 = pass)."""
import array
import math
import re
import sys
from pathlib import Path

# Import the function from the repo-root script copy.
sys.path.insert(0, str(Path(__file__).resolve().parent.parent))
from transcribe import plan_speech_chunks  # noqa: E402

RATE = 16000

def tone(seconds, amplitude=8000):
    return [int(amplitude * math.sin(2 * math.pi * 220 * t / RATE)) for t in range(int(seconds * RATE))]

def silence(seconds):
    return [0] * int(seconds * RATE)

def build(*parts):
    samples = array.array("h")
    for part in parts:
        samples.extend(part)
    return samples

failures = []

def check(name, condition):
    if not condition:
        failures.append(name)

# 1. Short file -> single chunk.
short = build(tone(30))
check("short file is one chunk", plan_speech_chunks(short, RATE) == [(0.0, 30.0)])

# 2. Long file with silences every ~100s: cuts land inside silences.
pattern = []
for _ in range(8):
    pattern.append(tone(100))
    pattern.append(silence(2))
long_audio = build(*pattern)
chunks = plan_speech_chunks(long_audio, RATE, target_chunk=150.0, max_chunk=300.0)
check("multiple chunks", len(chunks) >= 2)
check("chunks tile the file",
      abs(chunks[0][0]) < 1e-6 and abs(chunks[-1][1] - len(long_audio) / RATE) < 1e-6
      and all(abs(chunks[i][1] - chunks[i + 1][0]) < 1e-6 for i in range(len(chunks) - 1)))
silence_spans = []
cursor = 0.0
for _ in range(8):
    cursor += 100.0
    silence_spans.append((cursor, cursor + 2.0))
    cursor += 2.0
for _, end in chunks[:-1]:
    check(f"cut {end:.1f}s lands in a silence",
          any(s <= end <= e for s, e in silence_spans))

# 3. No silences at all -> single chunk despite length.
no_silence = build(tone(400))
check("no-silence file is one chunk", len(plan_speech_chunks(no_silence, RATE)) == 1)

if failures:
    print("FAILED:", "; ".join(failures))
    sys.exit(1)
print("chunk planning OK")
