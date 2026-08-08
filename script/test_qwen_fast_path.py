#!/usr/bin/env python3
"""Exercises Cue's Qwen adapter without downloading model weights."""

from __future__ import annotations

import array
import sys
import tempfile
import types
import unittest
import wave
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))
import transcribe  # noqa: E402


class FakeResult:
    text = "hello"
    segments = [{"start": 0.0, "end": 1.0, "text": "hello."}]


class FakeSession:
    instances = []

    def __init__(self, model):
        self.model = model
        self.calls = []
        self.__class__.instances.append(self)

    def transcribe(self, audio, **kwargs):
        self.calls.append((audio, kwargs))
        return FakeResult()


class FakeAligner:
    pass


class QwenFastPathTests(unittest.TestCase):
    def test_reuses_session_and_passes_numpy_chunks_without_temp_wavs(self):
        FakeSession.instances = []
        fake_module = types.ModuleType("mlx_qwen3_asr")
        fake_module.Session = FakeSession
        fake_module.ForcedAligner = FakeAligner
        fake_module.transcribe = lambda *_args, **_kwargs: FakeResult()
        previous = sys.modules.get("mlx_qwen3_asr")
        sys.modules["mlx_qwen3_asr"] = fake_module
        try:
            with tempfile.TemporaryDirectory() as directory:
                root = Path(directory)
                wav_path = root / "movie.wav"
                sample_rate = 100
                samples = array.array("h", [1_000] * (700 * sample_rate))
                silence_start = 90 * sample_rate
                for index in range(silence_start, silence_start + 2 * sample_rate):
                    samples[index] = 0
                with wave.open(str(wav_path), "wb") as output:
                    output.setnchannels(1)
                    output.setsampwidth(2)
                    output.setframerate(sample_rate)
                    output.writeframes(samples.tobytes())

                backend, segments, metrics = transcribe.load_with_qwen3(
                    wav_path,
                    "Qwen/Qwen3-ASR-1.7B",
                    "English",
                    stream_segments=True,
                    context="Arrakis Chani",
                )

                self.assertEqual(backend, "qwen3-asr")
                self.assertEqual(len(FakeSession.instances), 1)
                session = FakeSession.instances[0]
                self.assertEqual(len(session.calls), 2)
                self.assertEqual(metrics["chunkCount"], 2)
                self.assertEqual(len(segments), 2)
                aligner = session.calls[0][1]["forced_aligner"]
                for audio_input, kwargs in session.calls:
                    self.assertIsInstance(audio_input, tuple)
                    self.assertEqual(audio_input[1], sample_rate)
                    self.assertEqual(kwargs["context"], "Arrakis Chani")
                    self.assertIs(kwargs["forced_aligner"], aligner)
                self.assertEqual(list(root.glob("*.chunk*.wav")), [])
        finally:
            if previous is None:
                sys.modules.pop("mlx_qwen3_asr", None)
            else:
                sys.modules["mlx_qwen3_asr"] = previous


if __name__ == "__main__":
    unittest.main()
