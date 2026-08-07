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

PIP_PACKAGES = {
    "mlx-whisper": "mlx-whisper",
    "faster-whisper": "faster-whisper",
    "qwen3-asr": "'mlx-qwen3-asr[aligner]'",
}

# Top-level module each backend imports, used to tell "the backend is not
# installed" apart from "one of its dependencies is broken".
BACKEND_MODULES = {
    "mlx-whisper": "mlx_whisper",
    "faster-whisper": "faster_whisper",
    "qwen3-asr": "mlx_qwen3_asr",
}


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


def extract_audio(input_path: Path, output_path: Path, preprocess_audio: bool) -> bool:
    """Extracts audio; returns whether the cleanup filter chain was actually
    applied (the filtered run can fail and fall back to plain extraction)."""
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
    used_preprocess = preprocess_audio
    if returncode != 0 and preprocess_audio:
        emit("extractingAudio", "Audio cleanup failed; retrying plain extraction.", 0.1)
        returncode, stdout, stderr = run_child(base_command + output_args)
        used_preprocess = False

    if returncode != 0:
        raise RuntimeError(stderr.strip() or stdout.strip() or "ffmpeg failed")
    return used_preprocess


def prune_audio_cache(cache_dir: Path, keep: Path, max_bytes: int = 10 * 1024**3) -> None:
    """Extracted WAVs are ~110 MB per source hour and nothing else deletes
    them; drop the oldest entries once the cache passes max_bytes."""
    try:
        files = sorted(cache_dir.glob("*.wav"), key=lambda p: p.stat().st_mtime)
        total = sum(p.stat().st_size for p in files)
        for path in files:
            if total <= max_bytes:
                break
            if path == keep:
                continue
            size = path.stat().st_size
            path.unlink(missing_ok=True)
            total -= size
    except OSError:
        pass


def prepare_audio(input_path: Path, temp_dir: Path, preprocess_audio: bool, audio_wav: Path | None = None) -> Path:
    if audio_wav is not None and audio_wav.exists():
        emit("extractingAudio", "Using pre-extracted audio.", 0.12)
        return audio_wav

    cache_path = audio_cache_path(input_path, preprocess_audio)
    if cache_path.exists() and cache_path.stat().st_size > 0:
        emit("extractingAudio", "Using cached extracted audio.", 0.12)
        return cache_path

    temp_audio = temp_dir / "audio.wav"
    used_preprocess = extract_audio(input_path, temp_audio, preprocess_audio)
    if used_preprocess != preprocess_audio:
        # The filter chain failed and plain extraction was used: cache under
        # the key that matches the actual content, so a later Clean-audio run
        # retries the filters instead of silently reusing unfiltered audio.
        cache_path = audio_cache_path(input_path, used_preprocess)
    temp_audio.replace(cache_path)
    prune_audio_cache(cache_path.parent, keep=cache_path)
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


SENTENCE_ENDINGS = ("。", "！", "？", "!", "?", ".")


def join_token_text(previous: str, token: str) -> str:
    # Insert a space between latin words; CJK tokens concatenate directly.
    if previous and token and previous[-1].isascii() and previous[-1].isalnum() and token[0].isascii() and token[0].isalnum():
        return previous + " " + token
    return previous + token


def group_timed_tokens(tokens, max_chars=42, max_duration=6.0, max_gap=0.8):
    """Qwen3's aligner emits token-level timestamps; merge them into
    subtitle-sized segments, breaking at sentence endings, pauses, and
    length/duration caps."""
    groups = []
    current = None
    for token in tokens:
        text = token["text"]
        if not text:
            continue
        if current is not None:
            gap = token["start"] - current["end"]
            merged = join_token_text(current["text"], text)
            duration = token["end"] - current["start"]
            if gap > max_gap or len(merged) > max_chars or duration > max_duration:
                groups.append(current)
                current = None
            else:
                current["text"] = merged
                current["end"] = max(current["end"], token["end"])
                if current["text"].rstrip().endswith(SENTENCE_ENDINGS) and len(current["text"]) >= 8:
                    groups.append(current)
                    current = None
                continue
        if current is None:
            current = {"start": token["start"], "end": token["end"], "text": text}
    if current is not None:
        groups.append(current)
    return groups


def plan_speech_chunks(samples, sample_rate, min_silence=0.5, target_chunk=150.0, max_chunk=300.0):
    """Cut points for chunked ASR, placed only inside detected silences.

    samples: array('h') of 16-bit mono PCM. Returns [(start_s, end_s), ...]
    covering the whole file. A file with no usable silences returns a single
    chunk — never a mid-speech cut.
    """
    import math
    total_seconds = len(samples) / float(sample_rate)
    if total_seconds <= max_chunk:
        return [(0.0, total_seconds)]
    frame = max(1, int(sample_rate * 0.05))  # 50 ms frames
    rms = []
    for i in range(0, len(samples) - frame + 1, frame):
        window = samples[i:i + frame]
        rms.append(math.sqrt(sum(s * s for s in window) / len(window)))
    if not rms:
        return [(0.0, total_seconds)]
    threshold = max(1.0, 0.1 * sorted(rms)[int(len(rms) * 0.95)])
    frame_seconds = frame / float(sample_rate)
    # Candidate cut points: centers of silent runs >= min_silence.
    candidates = []
    run_start = None
    for index, value in enumerate(rms):
        if value < threshold:
            if run_start is None:
                run_start = index
        else:
            if run_start is not None:
                run_len = (index - run_start) * frame_seconds
                if run_len >= min_silence:
                    candidates.append((run_start + (index - run_start) / 2.0) * frame_seconds)
                run_start = None
    if run_start is not None and (len(rms) - run_start) * frame_seconds >= min_silence:
        candidates.append((run_start + (len(rms) - run_start) / 2.0) * frame_seconds)
    if not candidates:
        return [(0.0, total_seconds)]
    chunks = []
    start = 0.0
    for _ in range(10000):  # bounded; each iteration advances start
        remaining = total_seconds - start
        if remaining <= max_chunk:
            chunks.append((start, total_seconds))
            break
        in_window = [c for c in candidates if start + min_silence < c <= start + max_chunk]
        if in_window:
            cut = min(in_window, key=lambda c: abs(c - (start + target_chunk)))
        else:
            later = [c for c in candidates if c > start + max_chunk]
            if not later:
                chunks.append((start, total_seconds))
                break
            cut = later[0]  # first silence after the cap beats a mid-speech cut
        chunks.append((start, cut))
        start = cut
    return chunks


def load_with_qwen3(audio_path: Path, model: str, language: str, stream_segments: bool = False):
    from mlx_qwen3_asr import transcribe as qwen3_transcribe
    import array as _array
    import wave

    emit("loadingModel", f"Loading {model} with Qwen3 ASR. First run may download the model.", 0.18)

    chunks = [(0.0, None)]
    samples = None
    sample_rate = 16000
    if stream_segments:
        try:
            with wave.open(str(audio_path), "rb") as handle:
                sample_rate = handle.getframerate()
                raw = handle.readframes(handle.getnframes())
            samples = _array.array("h")
            samples.frombytes(raw)
            planned = plan_speech_chunks(samples, sample_rate)
            if len(planned) > 1:
                chunks = planned
        except Exception:
            chunks = [(0.0, None)]  # unreadable as plain WAV: fall back to one call

    all_tokens = []
    all_segments = []
    next_id = 1
    for chunk_index, (chunk_start, chunk_end) in enumerate(chunks):
        if chunk_end is None or len(chunks) == 1:
            chunk_path = audio_path
        else:
            chunk_path = audio_path.with_name(f"{audio_path.stem}.chunk{chunk_index}.wav")
            first = int(chunk_start * sample_rate)
            last = int(chunk_end * sample_rate)
            with wave.open(str(chunk_path), "wb") as out:
                out.setnchannels(1)
                out.setsampwidth(2)
                out.setframerate(sample_rate)
                out.writeframes(samples[first:last].tobytes())
        fraction = 0.2 + 0.7 * (chunk_index / max(1, len(chunks)))
        emit("transcribing", f"Transcribing chunk {chunk_index + 1} of {len(chunks)}.", fraction)
        # mlx_qwen3_asr.transcribe may reload the model per call if it does
        # not cache internally; acceptable in v1.
        result = call_with_supported_kwargs(
            qwen3_transcribe,
            str(chunk_path),
            model=model,
            language=None if language == "auto" else language,
            return_timestamps=True,
        )
        if chunk_path != audio_path:
            chunk_path.unlink(missing_ok=True)
        raw_segments = getattr(result, "segments", None) or []
        tokens = []
        for segment in raw_segments:
            if isinstance(segment, dict):
                start, end, text = segment.get("start", 0.0), segment.get("end", 0.0), segment.get("text", "")
            else:
                start = getattr(segment, "start", 0.0)
                end = getattr(segment, "end", 0.0)
                text = getattr(segment, "text", "")
            tokens.append({
                "start": float(start or 0.0) + chunk_start,
                "end": float(end or 0.0) + chunk_start,
                "text": str(text).strip(),
            })
        all_tokens.extend(tokens)
        batch = []
        for group in group_timed_tokens(tokens):
            batch.append({"id": next_id, "start": group["start"], "end": group["end"], "text": group["text"].strip()})
            next_id += 1
        all_segments.extend(batch)
        if stream_segments and batch:
            print(json.dumps({"event": "segments", "segments": batch}), file=sys.stderr, flush=True)

    emit("transcribing", "Normalizing transcript segments.", 0.92)
    segments = all_segments
    if not segments:
        # The loop always ran at least once, so `result` is bound.
        if str(getattr(result, "text", "") or "").strip():
            raise RuntimeError(
                "Qwen3 ASR produced text but no timestamps. Install the aligner extra: pip install 'mlx-qwen3-asr[aligner]'"
            )
        raise RuntimeError("Qwen3 ASR returned no transcript.")
    return "qwen3-asr", segments


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
    parser.add_argument("--backend", default="auto", choices=["auto", "mlx-whisper", "faster-whisper", "qwen3-asr"])
    parser.add_argument("--preprocess-audio", default="true")
    parser.add_argument("--audio-wav", default=None, help="Path to a pre-extracted 16 kHz mono WAV; skips ffmpeg extraction.")
    parser.add_argument("--vad-filter", default="true")
    parser.add_argument("--beam-size", type=int, default=5)
    parser.add_argument("--best-of", type=int, default=5)
    parser.add_argument("--temperature", type=float, default=0.0)
    parser.add_argument("--no-speech-threshold", type=float, default=0.6)
    parser.add_argument("--stream-segments", default="false")
    parser.add_argument("--json", action="store_true")
    args = parser.parse_args()

    input_path = Path(args.input_file)
    if not input_path.exists():
        print(f"File not found: {input_path}", file=sys.stderr)
        return 1

    with tempfile.TemporaryDirectory(prefix="whisperdesk_") as temp_dir:
        emit("preflight", "Preparing transcription helper.", 0.02)
        try:
            audio_path = prepare_audio(
                input_path,
                Path(temp_dir),
                bool_arg(args.preprocess_audio),
                audio_wav=Path(args.audio_wav) if args.audio_wav else None,
            )
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
                elif backend == "qwen3-asr":
                    used_backend, segments = load_with_qwen3(
                        audio_path,
                        args.model,
                        args.language,
                        bool_arg(args.stream_segments),
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
                if exc.name == BACKEND_MODULES.get(backend):
                    errors.append(f"{backend} is not installed (pip install {PIP_PACKAGES.get(backend, backend)}).")
                else:
                    # A missing transitive dependency is a broken install, not
                    # a missing backend; naming the real module avoids sending
                    # users down the wrong fix path.
                    errors.append(f"{backend} failed: its dependency '{exc.name}' is missing or broken ({exc}).")
            except Exception as exc:  # pragma: no cover
                errors.append(f"{backend} failed: {exc}")

    label = " or ".join(ordered_backends)
    print(
        f"Transcription failed using {label}.\n"
        + "\n".join(errors)
        + "\nInstall mlx-whisper (recommended on Apple Silicon), mlx-qwen3-asr[aligner] (best accuracy), or faster-whisper, then try again.",
        file=sys.stderr,
    )
    return 1


if __name__ == "__main__":
    raise SystemExit(main())
"""#
}
