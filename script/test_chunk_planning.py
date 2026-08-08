#!/usr/bin/env python3
"""Tests silence-aware Qwen chunk planning with synthetic audio."""

import array
import math
import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))
from transcribe import plan_speech_chunks  # noqa: E402


RATE = 16_000


def tone(seconds, amplitude=8_000):
    return [
        int(amplitude * math.sin(2 * math.pi * 220 * t / RATE))
        for t in range(int(seconds * RATE))
    ]


def silence(seconds):
    return [0] * int(seconds * RATE)


def build(*parts):
    samples = array.array("h")
    for part in parts:
        samples.extend(part)
    return samples


class SpeechChunkPlanningTests(unittest.TestCase):
    def test_short_file_is_one_chunk(self):
        self.assertEqual(plan_speech_chunks(build(tone(30)), RATE), [(0.0, 30.0)])

    def test_long_file_cuts_only_inside_silence(self):
        pattern = []
        for _ in range(8):
            pattern.extend([tone(100), silence(2)])
        audio = build(*pattern)
        chunks = plan_speech_chunks(audio, RATE, target_chunk=150.0, max_chunk=300.0)
        self.assertGreaterEqual(len(chunks), 2)
        self.assertAlmostEqual(chunks[0][0], 0.0)
        self.assertAlmostEqual(chunks[-1][1], len(audio) / RATE)
        for current, following in zip(chunks, chunks[1:]):
            self.assertAlmostEqual(current[1], following[0])

        silence_spans = []
        cursor = 0.0
        for _ in range(8):
            cursor += 100.0
            silence_spans.append((cursor, cursor + 2.0))
            cursor += 2.0
        for _, end in chunks[:-1]:
            self.assertTrue(
                any(start <= end <= finish for start, finish in silence_spans),
                f"cut {end:.1f}s did not land in silence",
            )

    def test_no_silence_keeps_one_chunk(self):
        self.assertEqual(len(plan_speech_chunks(build(tone(400)), RATE)), 1)


if __name__ == "__main__":
    unittest.main()
