import Foundation

enum BackendScriptWriter {
    static func ensureScript() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("whisperdesk_backend.py")
        let data = Data(BackendScript.source.utf8)

        if !FileManager.default.fileExists(atPath: url.path) || (try? Data(contentsOf: url)) != data {
            try data.write(to: url, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        }

        return url
    }
}

enum BackendScript {
    static let source = #"""
#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
import subprocess
import sys
import tempfile
from pathlib import Path


def emit(stage: str, detail: str, fraction=None) -> None:
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


def load_with_mlx(audio_path: Path, model: str, language: str):
    import mlx_whisper  # type: ignore

    emit("loadingModel", f"Loading {model} with MLX Whisper.", 0.18)
    result = mlx_whisper.transcribe(
        str(audio_path),
        path_or_hf_repo=model,
        language=None if language == "auto" else language,
        task="transcribe",
        word_timestamps=False,
        verbose=False,
    )
    emit("transcribing", "Normalizing transcript segments.", 0.92)
    return "mlx-whisper", [
        {
            "id": index,
            "start": float(segment["start"]),
            "end": float(segment["end"]),
            "text": str(segment["text"]).strip(),
        }
        for index, segment in enumerate(result["segments"], start=1)
    ]


def load_with_faster_whisper(audio_path: Path, model: str, language: str):
    from faster_whisper import WhisperModel  # type: ignore

    emit("loadingModel", f"Loading {model} with Faster Whisper.", 0.18)
    runner = WhisperModel(model, device="cpu", compute_type="int8")
    emit("transcribing", "Running Faster Whisper transcription.", 0.35)
    segments, _ = runner.transcribe(
        str(audio_path),
        language=None if language == "auto" else language,
        task="transcribe",
        beam_size=5,
        best_of=5,
        vad_filter=True,
    )
    return "faster-whisper", [
        {
            "id": index,
            "start": float(segment.start),
            "end": float(segment.end),
            "text": str(segment.text).strip(),
        }
        for index, segment in enumerate(segments, start=1)
    ]


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("input_file")
    parser.add_argument("--language", default="auto")
    parser.add_argument("--model", default="mlx-community/whisper-large-v3-turbo")
    parser.add_argument("--backend", default="auto", choices=["auto", "mlx-whisper", "faster-whisper"])
    parser.add_argument("--json", action="store_true")
    args = parser.parse_args()

    input_path = Path(args.input_file)
    if not input_path.exists():
        print(f"File not found: {input_path}", file=sys.stderr)
        return 1

    with tempfile.TemporaryDirectory(prefix="whisperdesk_") as temp_dir:
        emit("preflight", "Preparing transcription helper.", 0.02)
        audio_path = Path(temp_dir) / "audio.wav"
        try:
            extract_audio(input_path, audio_path)
        except FileNotFoundError:
            print("ffmpeg was not found. Install ffmpeg and make sure it is on your PATH.", file=sys.stderr)
            return 1
        except Exception as exc:
            print(f"Could not extract audio with ffmpeg: {exc}", file=sys.stderr)
            return 1

        errors = []
        ordered_backends = ["mlx-whisper", "faster-whisper"] if args.backend == "auto" else [args.backend]

        for backend in ordered_backends:
            try:
                emit("transcribing", f"Trying {backend}.", 0.14)
                if backend == "mlx-whisper":
                    used_backend, segments = load_with_mlx(audio_path, args.model, args.language)
                else:
                    used_backend, segments = load_with_faster_whisper(audio_path, args.model, args.language)
                emit("complete", f"Transcription complete with {used_backend}.", 1.0)
                json.dump({"backend": used_backend, "segments": segments}, sys.stdout, ensure_ascii=False)
                sys.stdout.write("\n")
                return 0
            except ModuleNotFoundError as exc:
                errors.append(f"{backend} is not installed (pip install {backend}).")
            except Exception as exc:  # pragma: no cover
                errors.append(f"{backend} failed: {exc}")

    label = " or ".join(ordered_backends)
    print(
        f"Transcription failed using {label}.\n"
        + "\n".join(errors)
        + "\nInstall mlx-whisper (recommended on Apple Silicon) or faster-whisper, then try again.",
        file=sys.stderr,
    )
    return 1


if __name__ == "__main__":
    raise SystemExit(main())
"""#
}
