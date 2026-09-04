#!/usr/bin/env python3
"""Exercises the helper's resident --serve loop with a fake faster-whisper."""

from __future__ import annotations

import contextlib
import io
import json
import sys
import tempfile
import types
import unittest
import wave
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))
import transcribe  # noqa: E402


class FakeSegment:
    def __init__(self, start, end, text):
        self.start = start
        self.end = end
        self.text = text


class FakeWhisperModel:
    instances = []

    def __init__(self, model, device=None, compute_type=None):
        self.model = model
        self.calls = []
        self.__class__.instances.append(self)

    def transcribe(self, audio, **kwargs):
        self.calls.append((audio, kwargs))
        return iter([FakeSegment(0.0, 1.0, " hello "), FakeSegment(1.0, 2.0, "world")]), None


def write_wav(path: Path) -> None:
    with wave.open(str(path), "wb") as output:
        output.setnchannels(1)
        output.setsampwidth(2)
        output.setframerate(16000)
        output.writeframes(b"\x00\x00" * 16000)


class ServeModeTests(unittest.TestCase):
    def setUp(self):
        FakeWhisperModel.instances = []
        transcribe.MODEL_CACHE.clear()
        fake_module = types.ModuleType("faster_whisper")
        fake_module.WhisperModel = FakeWhisperModel
        self.previous = sys.modules.get("faster_whisper")
        sys.modules["faster_whisper"] = fake_module

    def tearDown(self):
        transcribe.MODEL_CACHE.clear()
        if self.previous is None:
            sys.modules.pop("faster_whisper", None)
        else:
            sys.modules["faster_whisper"] = self.previous

    def run_serve(self, requests):
        stdin = io.StringIO("".join(json.dumps(request) + "\n" for request in requests))
        stdout = io.StringIO()
        stderr = io.StringIO()
        original_stdin = sys.stdin
        sys.stdin = stdin
        try:
            with contextlib.redirect_stdout(stdout), contextlib.redirect_stderr(stderr):
                status = transcribe.serve(transcribe.build_parser())
        finally:
            sys.stdin = original_stdin
        lines = [json.loads(line) for line in stderr.getvalue().splitlines() if line.startswith("{")]
        return status, stdout.getvalue(), lines

    def job(self, job_id, input_path, audio_wav, backend="faster-whisper", model="large-v3-turbo"):
        return {
            "event": "job",
            "id": job_id,
            "input_path": str(input_path),
            "audio_wav": str(audio_wav),
            "language": "en",
            "qwen_context": "",
            "model": model,
            "backend": backend,
            "preprocess_audio": False,
            "vad_filter": True,
            "beam_size": 5,
            "best_of": 5,
            "temperature": 0.0,
            "no_speech_threshold": 0.6,
            "stream_segments": True,
            "resume_through_seconds": 0.0,
            "starting_segment_id": 1,
        }

    def test_model_loads_once_across_jobs_and_errors_do_not_end_the_loop(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            media = root / "movie.mp4"
            media.write_bytes(b"not really media")
            wav = root / "movie.wav"
            write_wav(wav)
            status, stdout, lines = self.run_serve(
                [
                    self.job("a", media, wav),
                    self.job("b", media, wav),
                    {"event": "job", "id": "c", "input_path": str(media), "audio_wav": str(wav), "backend": "nope"},
                    self.job("d", root / "missing.mp4", wav),
                    {"event": "shutdown"},
                    self.job("never", media, wav),
                ]
            )

        self.assertEqual(status, 0)
        self.assertEqual(stdout, "", "serve mode must keep stdout silent")
        self.assertEqual(len(FakeWhisperModel.instances), 1, "the model must load once for both jobs")
        self.assertEqual(len(FakeWhisperModel.instances[0].calls), 2)

        results = [line for line in lines if line.get("event") == "result"]
        errors = [line for line in lines if line.get("event") == "error"]
        self.assertEqual([r["id"] for r in results], ["a", "b"])
        self.assertEqual([e["id"] for e in errors], ["c", "d"])
        self.assertIn("argparse", errors[0]["message"])
        self.assertIn("File not found", errors[1]["message"])
        for result in results:
            self.assertEqual(result["backend"], "faster-whisper")
            self.assertEqual([s["text"] for s in result["segments"]], ["hello", "world"])
            self.assertEqual([s["id"] for s in result["segments"]], [1, 2])

        # Each job's stderr stream keeps the one-shot ordering: preflight,
        # loading, complete, then the result as the final line for that job.
        stages = [line.get("stage") or line.get("event") for line in lines]
        first_result = stages.index("result")
        self.assertEqual(stages[:first_result], ["preflight", "extractingAudio", "transcribing", "loadingModel", "transcribing", "complete"])

    def test_one_shot_cli_still_writes_json_to_stdout(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            media = root / "movie.mp4"
            media.write_bytes(b"not really media")
            wav = root / "movie.wav"
            write_wav(wav)
            argv = sys.argv
            stdout = io.StringIO()
            stderr = io.StringIO()
            sys.argv = [
                "transcribe.py", str(media), "--json", "--backend", "faster-whisper",
                "--audio-wav", str(wav), "--preprocess-audio", "false",
            ]
            try:
                with contextlib.redirect_stdout(stdout), contextlib.redirect_stderr(stderr):
                    status = transcribe.main()
            finally:
                sys.argv = argv
        self.assertEqual(status, 0)
        payload = json.loads(stdout.getvalue().strip().splitlines()[-1])
        self.assertEqual(payload["backend"], "faster-whisper")
        self.assertEqual([s["text"] for s in payload["segments"]], ["hello", "world"])
        self.assertNotIn('"event": "result"', stderr.getvalue())


if __name__ == "__main__":
    unittest.main()
