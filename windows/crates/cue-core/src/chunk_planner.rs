//! Port of `TranscriptionChunkPlanner` (Sources/Services/TranscriptionChunkPlanner.swift).
//!
//! Long audio is cut at silences into chunks (first one short so the first
//! subtitles arrive fast, then ~5 min each, never over 10 min). Each chunk is
//! a resume point: a job interrupted mid-file restarts at the first chunk not
//! yet finished. The cut rules match the macOS engine and the Python helper's
//! `plan_speech_chunks`, so resume boundaries agree across backends.

use crate::segment::Segment;

pub const DEFAULT_MIN_SILENCE: f64 = 0.5;
pub const DEFAULT_TARGET_CHUNK: f64 = 300.0;
pub const DEFAULT_MAX_CHUNK: f64 = 600.0;
pub const DEFAULT_FIRST_TARGET: f64 = 90.0;

/// Half-open time range `[start, end)` in seconds.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct SpeechChunk {
    pub start: f64,
    pub end: f64,
}

#[derive(Debug, Clone, Copy, PartialEq)]
pub struct ChunkPlanning {
    pub min_silence: f64,
    pub target_chunk: f64,
    pub max_chunk: f64,
    pub first_target: f64,
}

impl Default for ChunkPlanning {
    fn default() -> Self {
        Self {
            min_silence: DEFAULT_MIN_SILENCE,
            target_chunk: DEFAULT_TARGET_CHUNK,
            max_chunk: DEFAULT_MAX_CHUNK,
            first_target: DEFAULT_FIRST_TARGET,
        }
    }
}

/// Chunks ending at or before `resume_through` are already done.
pub fn pending_chunks(chunks: &[SpeechChunk], resume_through: f64) -> Vec<SpeechChunk> {
    if resume_through <= 0.0 {
        return chunks.to_vec();
    }
    chunks.iter().copied().filter(|c| c.end > resume_through + 0.01).collect()
}

/// Merge a freshly transcribed batch into saved partials without duplicating
/// cues from an interrupted re-run of the same chunk.
pub fn merge_partial_segments(existing: &[Segment], batch: &[Segment]) -> Vec<Segment> {
    if batch.is_empty() {
        return existing.to_vec();
    }
    let replace_from = batch.iter().map(|s| s.start).fold(f64::INFINITY, f64::min);
    let mut merged: Vec<Segment> = existing.iter().filter(|s| s.end <= replace_from + 0.01).cloned().collect();
    merged.extend_from_slice(batch);
    merged
}

/// Plan cut points using RMS silence detection. `samples` are mono floats in
/// [-1, 1].
pub fn plan_speech_chunks(samples: &[f32], sample_rate: usize, planning: ChunkPlanning) -> Vec<SpeechChunk> {
    let total = samples.len() as f64 / sample_rate as f64;
    let whole = vec![SpeechChunk { start: 0.0, end: total }];
    if total <= planning.max_chunk {
        return whole;
    }
    let frame = ((sample_rate as f64 * 0.05) as usize).max(1);
    let values = frame_rms(samples, frame);
    let peak = values.iter().copied().fold(f32::NEG_INFINITY, f32::max);
    if values.is_empty() || peak <= 0.0 {
        return whole;
    }
    let mut sorted = values.clone();
    sorted.sort_by(|a, b| a.total_cmp(b));
    let idx = ((sorted.len() - 1) as f64 * 0.95) as usize;
    let reference = sorted[idx.min(sorted.len() - 1)];
    // Python works on raw int16, so its floor of 1.0 is 1/32768 here.
    let threshold = (1.0 / 32_768.0f64).max(0.1 * reference as f64);
    let frame_seconds = frame as f64 / sample_rate as f64;
    let candidates = silence_candidates(&values, frame_seconds, threshold, planning.min_silence);
    if candidates.is_empty() {
        return whole;
    }
    choose_cuts(&candidates, total, planning)
}

/// RMS of each whole `frame`-sample window; the trailing partial frame is dropped.
pub fn frame_rms(samples: &[f32], frame: usize) -> Vec<f32> {
    samples.chunks_exact(frame).map(|w| (w.iter().map(|s| s * s).sum::<f32>() / frame as f32).sqrt()).collect()
}

/// Centres (in seconds) of every silent run at least `min_silence` long.
pub fn silence_candidates(rms: &[f32], frame_seconds: f64, threshold: f64, min_silence: f64) -> Vec<f64> {
    let mut candidates = Vec::new();
    let mut run_start: Option<usize> = None;
    let close = |start: usize, end: usize, out: &mut Vec<f64>| {
        if (end - start) as f64 * frame_seconds >= min_silence {
            let center = start as f64 + (end - start) as f64 / 2.0;
            out.push(center * frame_seconds);
        }
    };
    for (i, v) in rms.iter().enumerate() {
        if (*v as f64) < threshold {
            run_start.get_or_insert(i);
        } else if let Some(start) = run_start.take() {
            close(start, i, &mut candidates);
        }
    }
    if let Some(start) = run_start {
        close(start, rms.len(), &mut candidates);
    }
    candidates
}

pub fn choose_cuts(candidates: &[f64], total: f64, p: ChunkPlanning) -> Vec<SpeechChunk> {
    let mut chunks = Vec::new();
    let mut start = 0.0;
    for _ in 0..10_000 {
        if total - start <= p.max_chunk {
            chunks.push(SpeechChunk { start, end: total });
            break;
        }
        let lower = upper_bound(candidates, start + p.min_silence);
        let upper = upper_bound(candidates, start + p.max_chunk);
        let desired = if chunks.is_empty() { p.first_target } else { p.target_chunk };
        let cut = if lower < upper {
            let goal = start + desired;
            let mut best = candidates[lower];
            for &c in &candidates[lower + 1..upper] {
                if (c - goal).abs() < (best - goal).abs() {
                    best = c;
                }
            }
            best
        } else if upper < candidates.len() {
            candidates[upper]
        } else {
            chunks.push(SpeechChunk { start, end: total });
            break;
        };
        chunks.push(SpeechChunk { start, end: cut });
        start = cut;
    }
    chunks
}

fn upper_bound(values: &[f64], value: f64) -> usize {
    values.partition_point(|v| *v <= value)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn short_audio_is_one_chunk() {
        let samples = vec![0.1f32; 16_000 * 10];
        assert_eq!(plan_speech_chunks(&samples, 16_000, ChunkPlanning::default()), vec![SpeechChunk { start: 0.0, end: 10.0 }]);
    }

    #[test]
    fn long_audio_cuts_at_silences_near_targets() {
        // 20 minutes of tone with a 1 s silence every 30 s.
        let sr = 1_000;
        let mut samples = Vec::with_capacity(sr * 1200);
        for second in 0..1200 {
            let silent = second % 30 == 29;
            samples.extend(std::iter::repeat_n(if silent { 0.0 } else { 0.5 }, sr));
        }
        let chunks = plan_speech_chunks(&samples, sr, ChunkPlanning::default());
        assert!(chunks.len() >= 3);
        assert!((chunks[0].end - 89.5).abs() < 0.1, "first cut near 90 s, got {}", chunks[0].end);
        for pair in chunks.windows(2) {
            assert_eq!(pair[0].end, pair[1].start);
        }
        assert!(chunks.iter().all(|c| c.end - c.start <= 600.0));
        assert_eq!(chunks.last().unwrap().end, 1200.0);
    }

    #[test]
    fn pending_and_merge_follow_resume_frontier() {
        let chunks = [SpeechChunk { start: 0.0, end: 90.0 }, SpeechChunk { start: 90.0, end: 400.0 }];
        assert_eq!(pending_chunks(&chunks, 90.0), vec![chunks[1]]);
        let saved = vec![Segment::new(1, 0.0, 90.0, "a"), Segment::new(2, 95.0, 97.0, "stale")];
        let merged = merge_partial_segments(&saved, &[Segment::new(2, 92.0, 94.0, "b")]);
        assert_eq!(merged.iter().map(|s| s.text.as_str()).collect::<Vec<_>>(), vec!["a", "b"]);
    }
}
