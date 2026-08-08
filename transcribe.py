#!/usr/bin/env python3
"""
Local subtitle generation helper for Cue (formerly WhisperDesk).

Examples:
    python3 transcribe.py clip.mp4
    python3 transcribe.py clip.mp4 --language ja --json
    python3 transcribe.py clip.mp4 --backend faster-whisper --model large-v3
"""

from __future__ import annotations

import argparse
import inspect
import json
import subprocess
import sys
import tempfile
from pathlib import Path
from typing import Any


def emit(stage: str, detail: str, fraction: float | None = None) -> None:
    payload = {"stage": stage, "detail": detail, "fraction": fraction}
    print(json.dumps(payload), file=sys.stderr, flush=True)


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


def transcribe(
    input_path: Path, model: str, language: str, backend: str, stream_segments: bool = False
) -> dict[str, Any]:
    with tempfile.TemporaryDirectory(prefix="cue_") as temp_dir:
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
                elif strategy == "qwen3-asr":
                    used_backend, segments = load_with_qwen3(audio_path, model, language, stream_segments)
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
    parser.add_argument("--backend", default="auto", choices=["auto", "mlx-whisper", "faster-whisper", "qwen3-asr"])
    parser.add_argument("--stream-segments", default="false")
    parser.add_argument("--json", action="store_true")
    args = parser.parse_args()

    input_path = Path(args.input_file).expanduser().resolve()
    if not input_path.exists():
        print(f"File not found: {input_path}", file=sys.stderr)
        return 1

    result = transcribe(input_path, args.model, args.language, args.backend, bool_arg(args.stream_segments))
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
