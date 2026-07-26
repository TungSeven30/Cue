#!/usr/bin/env python3
"""
Local subtitle generation helper for WhisperDesk.

Examples:
    python3 transcribe.py clip.mp4
    python3 transcribe.py clip.mp4 --language ja --json
    python3 transcribe.py clip.mp4 --backend faster-whisper --model large-v3
"""

from __future__ import annotations

import argparse
import json
import subprocess
import sys
import tempfile
from pathlib import Path
from typing import Any


def emit(stage: str, detail: str, fraction: float | None = None) -> None:
    payload = {"stage": stage, "detail": detail, "fraction": fraction}
    print(json.dumps(payload), file=sys.stderr, flush=True)


def extract_audio(input_path: Path, output_path: Path) -> None:
    emit("extractingAudio", "Extracting audio with ffmpeg.", 0.08)
    process = subprocess.run(
        [
            "ffmpeg",
            "-y",
            "-i",
            str(input_path),
            "-vn",
            "-acodec",
            "pcm_s16le",
            "-ar",
            "16000",
            "-ac",
            "1",
            str(output_path),
        ],
        capture_output=True,
        text=True,
    )
    if process.returncode != 0:
        raise RuntimeError(process.stderr.strip() or "ffmpeg failed")


def format_timestamp(seconds: float) -> str:
    # Round to whole milliseconds first so the carry rolls into seconds;
    # rounding the fraction alone can produce an invalid ",1000" field.
    total_millis = max(0, round(seconds * 1000))
    millis = total_millis % 1000
    total_seconds = total_millis // 1000
    hours = total_seconds // 3600
    minutes = (total_seconds % 3600) // 60
    secs = total_seconds % 60
    return f"{hours:02d}:{minutes:02d}:{secs:02d},{millis:03d}"


def load_with_mlx(audio_path: Path, model: str, language: str) -> tuple[str, list[dict[str, Any]]]:
    import mlx_whisper  # type: ignore

    emit("loadingModel", f"Loading {model} with MLX Whisper.", 0.18)
    result = mlx_whisper.transcribe(
        str(audio_path),
        path_or_hf_repo=model,
        language=None if language == "auto" else language,
        word_timestamps=False,
        task="transcribe",
        verbose=False,
    )
    emit("transcribing", "Normalizing transcript segments.", 0.92)
    segments = [
        {
            "id": index,
            "start": float(segment["start"]),
            "end": float(segment["end"]),
            "text": str(segment["text"]).strip(),
        }
        for index, segment in enumerate(result["segments"], start=1)
    ]
    return "mlx-whisper", segments


def load_with_faster_whisper(audio_path: Path, model: str, language: str) -> tuple[str, list[dict[str, Any]]]:
    from faster_whisper import WhisperModel  # type: ignore

    emit("loadingModel", f"Loading {model} with Faster Whisper.", 0.18)
    model_runner = WhisperModel(model, device="cpu", compute_type="int8")
    emit("transcribing", "Running Faster Whisper transcription.", 0.35)
    segments, _ = model_runner.transcribe(
        str(audio_path),
        language=None if language == "auto" else language,
        task="transcribe",
        beam_size=5,
        best_of=5,
        vad_filter=True,
    )
    normalized = [
        {
            "id": index,
            "start": float(segment.start),
            "end": float(segment.end),
            "text": str(segment.text).strip(),
        }
        for index, segment in enumerate(segments, start=1)
    ]
    return "faster-whisper", normalized


def transcribe(input_path: Path, model: str, language: str, backend: str) -> dict[str, Any]:
    with tempfile.TemporaryDirectory(prefix="whisperdesk_") as temp_dir:
        emit("preflight", "Preparing transcription helper.", 0.02)
        audio_path = Path(temp_dir) / "audio.wav"
        extract_audio(input_path, audio_path)

        errors: list[str] = []
        strategies: list[str]
        if backend == "auto":
            strategies = ["mlx-whisper", "faster-whisper"]
        else:
            strategies = [backend]

        for strategy in strategies:
            try:
                emit("transcribing", f"Trying {strategy}.", 0.14)
                if strategy == "mlx-whisper":
                    used_backend, segments = load_with_mlx(audio_path, model, language)
                elif strategy == "faster-whisper":
                    used_backend, segments = load_with_faster_whisper(audio_path, model, language)
                else:
                    raise RuntimeError(f"Unsupported backend: {strategy}")
                emit("complete", f"Transcription complete with {used_backend}.", 1.0)
                return {
                    "backend": used_backend,
                    "language": language,
                    "model": model,
                    "segments": segments,
                }
            except Exception as exc:  # pragma: no cover - best effort helper
                errors.append(f"{strategy}: {exc}")

        joined = "\n".join(errors) if errors else "No backend attempts were made."
        raise RuntimeError(
            "Unable to transcribe. Install either `mlx-whisper` or `faster-whisper`.\n"
            f"{joined}"
        )


def write_srt(output_path: Path, segments: list[dict[str, Any]]) -> None:
    with output_path.open("w", encoding="utf-8") as handle:
        for segment in segments:
            handle.write(f"{segment['id']}\n")
            handle.write(
                f"{format_timestamp(segment['start'])} --> {format_timestamp(segment['end'])}\n"
            )
            handle.write(f"{segment['text']}\n\n")


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("input_file")
    parser.add_argument("--language", default="auto")
    parser.add_argument("--model", default="mlx-community/whisper-large-v3-turbo")
    parser.add_argument("--backend", default="auto", choices=["auto", "mlx-whisper", "faster-whisper"])
    parser.add_argument("--json", action="store_true")
    args = parser.parse_args()

    input_path = Path(args.input_file).expanduser().resolve()
    if not input_path.exists():
        print(f"File not found: {input_path}", file=sys.stderr)
        return 1

    result = transcribe(input_path, args.model, args.language, args.backend)
    if args.json:
        json.dump(result, sys.stdout, ensure_ascii=False, indent=2)
        sys.stdout.write("\n")
    else:
        output_path = input_path.with_suffix(".srt")
        write_srt(output_path, result["segments"])
        print(output_path)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
