//! Mirrors `TranslationBatchPlanner` and `TranslationChunkMode`
//! (Sources/Services/TranslationBatchPlanner.swift, Sources/Models/AppSettingsStore.swift).
//! Only contiguous untranslated runs are planned, so a resumed run never
//! retransmits finished subtitles.

use crate::Segment;
use std::collections::HashSet;

#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub enum ChunkMode {
    Safer,
    #[default]
    Balanced,
    Faster,
}

impl ChunkMode {
    pub fn parse(name: &str) -> Option<ChunkMode> {
        match name.trim().to_lowercase().as_str() {
            "safer" => Some(ChunkMode::Safer),
            "balanced" => Some(ChunkMode::Balanced),
            "faster" => Some(ChunkMode::Faster),
            _ => None,
        }
    }

    /// Hard cap on segments per request.
    pub fn chunk_size(self) -> usize {
        match self {
            ChunkMode::Safer => 40,
            ChunkMode::Balanced => 80,
            ChunkMode::Faster => 120,
        }
    }

    /// Approximate input budget per request; text size predicts latency and
    /// output-limit failures better than segment count (CJK above all).
    pub fn target_input_tokens(self) -> usize {
        match self {
            ChunkMode::Safer => 1_800,
            ChunkMode::Balanced => 3_200,
            ChunkMode::Faster => 5_000,
        }
    }
}

/// Latin text averages about four characters per token; CJK is counted
/// conservatively as one scalar per token.
pub fn estimated_tokens(text: &str) -> usize {
    let (mut ascii, mut non_ascii) = (0usize, 0usize);
    for c in text.chars() {
        if c.is_ascii() {
            ascii += 1;
        } else {
            non_ascii += 1;
        }
    }
    (ascii.div_ceil(4) + non_ascii).max(1)
}

/// Per-segment JSON and id overhead the estimate adds.
const SEGMENT_OVERHEAD: usize = 12;

pub fn pending_chunks(segments: &[Segment], translated_ids: &HashSet<i64>, mode: ChunkMode) -> Vec<Vec<Segment>> {
    let mut result = Vec::new();
    let mut current: Vec<Segment> = Vec::new();
    let mut current_tokens = 0usize;
    for segment in segments {
        if translated_ids.contains(&segment.id) {
            // Never bridge an already translated range: progressive chunk
            // boundaries must stay stable.
            if !current.is_empty() {
                result.push(std::mem::take(&mut current));
                current_tokens = 0;
            }
            continue;
        }
        let tokens = estimated_tokens(&segment.text) + SEGMENT_OVERHEAD;
        if !current.is_empty() && (current.len() >= mode.chunk_size() || current_tokens + tokens > mode.target_input_tokens()) {
            result.push(std::mem::take(&mut current));
            current_tokens = 0;
        }
        current.push(segment.clone());
        current_tokens += tokens;
    }
    if !current.is_empty() {
        result.push(current);
    }
    result
}

#[cfg(test)]
mod tests {
    use super::*;

    fn seg(id: i64, text: &str) -> Segment {
        Segment::new(id, id as f64, id as f64 + 1.0, text)
    }

    #[test]
    fn token_estimate_counts_cjk_per_scalar() {
        assert_eq!(estimated_tokens(""), 1);
        assert_eq!(estimated_tokens("abcd"), 1);
        assert_eq!(estimated_tokens("abcde"), 2);
        assert_eq!(estimated_tokens("日本語"), 3);
    }

    #[test]
    fn chunks_respect_the_segment_cap() {
        let segments: Vec<_> = (1..=100).map(|i| seg(i, "hi")).collect();
        let chunks = pending_chunks(&segments, &HashSet::new(), ChunkMode::Safer);
        assert_eq!(chunks.iter().map(Vec::len).collect::<Vec<_>>(), vec![40, 40, 20]);
    }

    #[test]
    fn chunks_respect_the_token_budget() {
        let long = "x".repeat(4 * 500);
        let segments: Vec<_> = (1..=10).map(|i| seg(i, &long)).collect();
        // 512 tokens each; 1800 fits three.
        let chunks = pending_chunks(&segments, &HashSet::new(), ChunkMode::Safer);
        assert_eq!(chunks.iter().map(Vec::len).collect::<Vec<_>>(), vec![3, 3, 3, 1]);
    }

    #[test]
    fn translated_ranges_split_chunks_and_are_skipped() {
        let segments: Vec<_> = (1..=6).map(|i| seg(i, "hi")).collect();
        let done: HashSet<i64> = [3, 4].into_iter().collect();
        let chunks = pending_chunks(&segments, &done, ChunkMode::Balanced);
        let ids: Vec<Vec<i64>> = chunks.iter().map(|c| c.iter().map(|s| s.id).collect()).collect();
        assert_eq!(ids, vec![vec![1, 2], vec![5, 6]]);
    }

    #[test]
    fn a_single_oversized_segment_still_gets_a_chunk() {
        let segments = vec![seg(1, &"y".repeat(40_000))];
        assert_eq!(pending_chunks(&segments, &HashSet::new(), ChunkMode::Safer).len(), 1);
    }
}
