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
import hashlib
import inspect
import json
import signal
import subprocess
import sys
import tempfile
import threading
from pathlib import Path

ACTIVE_CHILDREN = set()
ACTIVE_LOCK = threading.Lock()


def emit(stage: str, detail: str, fraction=None) -> None:
    payload = {"stage": stage, "detail": detail, "fraction": fraction}
    print(json.dumps(payload), file=sys.stderr, flush=True)


def terminate_children(signum=None, frame=None) -> None:
    with ACTIVE_LOCK:
        children = list(ACTIVE_CHILDREN)
    for process in children:
        if process.poll() is None:
            try:
                process.terminate()
            except Exception:
                pass


def handle_termination(signum=None, frame=None) -> None:
    # Exit after cleaning up children. Without the exit, a cancel arriving
    # during model inference (no children running) would be swallowed and
    # transcription would keep running after the app reported "Canceled".
    terminate_children()
    sys.exit(130)


signal.signal(signal.SIGTERM, handle_termination)
signal.signal(signal.SIGINT, handle_termination)


def bool_arg(value: str) -> bool:
    return value.strip().lower() in {"1", "true", "yes", "on"}


def call_with_supported_kwargs(function, *args, **kwargs):
    try:
        signature = inspect.signature(function)
    except (TypeError, ValueError):
        return function(*args, **kwargs)
    if any(parameter.kind == inspect.Parameter.VAR_KEYWORD for parameter in signature.parameters.values()):
        return function(*args, **kwargs)
    supported = {key: value for key, value in kwargs.items() if key in signature.parameters}
    return function(*args, **supported)


def audio_cache_path(input_path: Path, preprocess_audio: bool) -> Path:
    stat = input_path.stat()
    payload = f"{input_path.resolve()}|{stat.st_size}|{stat.st_mtime_ns}|preprocess={preprocess_audio}".encode("utf-8")
    digest = hashlib.sha256(payload).hexdigest()[:24]
    cache_dir = Path.home() / "Library" / "Caches" / "WhisperDesk" / "audio"
    cache_dir.mkdir(parents=True, exist_ok=True)
    return cache_dir / f"{digest}.wav"


def run_child(command: list[str]) -> tuple[int, str, str]:
    process = subprocess.Popen(
        command,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
    )
    with ACTIVE_LOCK:
        ACTIVE_CHILDREN.add(process)
    stdout, stderr = process.communicate()
    with ACTIVE_LOCK:
        ACTIVE_CHILDREN.discard(process)
    return process.returncode, stdout, stderr


def extract_audio(input_path: Path, output_path: Path, preprocess_audio: bool) -> None:
    detail = "Extracting and cleaning audio with ffmpeg." if preprocess_audio else "Extracting audio with ffmpeg."
    emit("extractingAudio", detail, 0.08)
    base_command = [
        "ffmpeg",
        "-y",
        "-i",
        str(input_path),
        "-vn",
    ]
    filter_args = []
    if preprocess_audio:
        filter_args = [
            "-af",
            "highpass=f=80,afftdn=nf=-25,loudnorm=I=-16:TP=-1.5:LRA=11",
        ]
    output_args = [
        "-acodec",
        "pcm_s16le",
        "-ar",
        "16000",
        "-ac",
        "1",
        str(output_path),
    ]
    returncode, stdout, stderr = run_child(base_command + filter_args + output_args)
    if returncode != 0 and preprocess_audio:
        emit("extractingAudio", "Audio cleanup failed; retrying plain extraction.", 0.1)
        returncode, stdout, stderr = run_child(base_command + output_args)
    
    if returncode != 0:
        raise RuntimeError(stderr.strip() or stdout.strip() or "ffmpeg failed")


def prepare_audio(input_path: Path, temp_dir: Path, preprocess_audio: bool) -> Path:
    cache_path = audio_cache_path(input_path, preprocess_audio)
    if cache_path.exists() and cache_path.stat().st_size > 0:
        emit("extractingAudio", "Using cached extracted audio.", 0.12)
        return cache_path

    temp_audio = temp_dir / "audio.wav"
    extract_audio(input_path, temp_audio, preprocess_audio)
    temp_audio.replace(cache_path)
    return cache_path


def load_with_mlx(audio_path: Path, model: str, language: str, temperature: float, no_speech_threshold: float):
    import mlx_whisper  # type: ignore

    emit("loadingModel", f"Loading {model} with MLX Whisper. First run may download the model.", 0.18)
    result = call_with_supported_kwargs(
        mlx_whisper.transcribe,
        str(audio_path),
        path_or_hf_repo=model,
        language=None if language == "auto" else language,
        task="transcribe",
        word_timestamps=False,
        temperature=temperature,
        no_speech_threshold=no_speech_threshold,
        condition_on_previous_text=False,
        compression_ratio_threshold=2.4,
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


def faster_whisper_model(model: str) -> str:
    model = model.strip()
    if model in {"mlx-community/whisper-large-v3-turbo", "openai/whisper-large-v3-turbo"}:
        return "large-v3-turbo"
    if model in {"mlx-community/whisper-large-v3", "openai/whisper-large-v3"}:
        return "large-v3"
    if model.startswith("mlx-community/whisper-"):
        return model.removeprefix("mlx-community/whisper-")
    return model or "large-v3-turbo"


def load_with_faster_whisper(
    audio_path: Path,
    model: str,
    language: str,
    vad_filter: bool,
    beam_size: int,
    best_of: int,
    temperature: float,
    no_speech_threshold: float,
):
    from faster_whisper import WhisperModel  # type: ignore

    resolved_model = faster_whisper_model(model)
    if resolved_model == model:
        emit("loadingModel", f"Loading {resolved_model} with Faster Whisper. First run may download the model.", 0.18)
    else:
        emit("loadingModel", f"Loading {resolved_model} with Faster Whisper (mapped from {model}). First run may download the model.", 0.18)
    runner = WhisperModel(resolved_model, device="cpu", compute_type="int8")
    emit("transcribing", "Running Faster Whisper transcription.", 0.35)
    segments, _ = call_with_supported_kwargs(
        runner.transcribe,
        str(audio_path),
        language=None if language == "auto" else language,
        task="transcribe",
        beam_size=beam_size,
        best_of=best_of,
        temperature=temperature,
        vad_filter=vad_filter,
        vad_parameters={
            "min_silence_duration_ms": 700,
            "speech_pad_ms": 350,
        } if vad_filter else None,
        no_speech_threshold=no_speech_threshold,
        condition_on_previous_text=False,
        compression_ratio_threshold=2.4,
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
    parser.add_argument("--preprocess-audio", default="true")
    parser.add_argument("--vad-filter", default="true")
    parser.add_argument("--beam-size", type=int, default=5)
    parser.add_argument("--best-of", type=int, default=5)
    parser.add_argument("--temperature", type=float, default=0.0)
    parser.add_argument("--no-speech-threshold", type=float, default=0.6)
    parser.add_argument("--json", action="store_true")
    args = parser.parse_args()

    input_path = Path(args.input_file)
    if not input_path.exists():
        print(f"File not found: {input_path}", file=sys.stderr)
        return 1

    with tempfile.TemporaryDirectory(prefix="whisperdesk_") as temp_dir:
        emit("preflight", "Preparing transcription helper.", 0.02)
        try:
            audio_path = prepare_audio(input_path, Path(temp_dir), bool_arg(args.preprocess_audio))
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
                    used_backend, segments = load_with_mlx(
                        audio_path,
                        args.model,
                        args.language,
                        args.temperature,
                        args.no_speech_threshold,
                    )
                else:
                    used_backend, segments = load_with_faster_whisper(
                        audio_path,
                        args.model,
                        args.language,
                        bool_arg(args.vad_filter),
                        max(1, args.beam_size),
                        max(1, args.best_of),
                        args.temperature,
                        args.no_speech_threshold,
                    )
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
