//! Port of `TranscriptionPostProcessor` (Sources/Services/TranscriptionService.swift).
//!
//! Every backend's raw output runs through the same cleanup so a transcript
//! does not depend on which engine produced it: whitespace normalization,
//! repeated-phrase collapsing, duplicate and echo removal, empty-cue removal,
//! optional short-cue merging, and timing repair.

use crate::chunk_planner;
use crate::segment::Segment;

/// The cleanup knobs from the job's settings snapshot.
#[derive(Debug, Clone, PartialEq)]
pub struct CleanupSettings {
    pub remove_empty_segments: bool,
    pub remove_repeated_text: bool,
    pub merge_short_segments: bool,
    pub min_segment_duration: f64,
    pub max_merge_gap: f64,
}

impl Default for CleanupSettings {
    /// The macOS app's defaults.
    fn default() -> Self {
        Self {
            remove_empty_segments: true,
            remove_repeated_text: true,
            merge_short_segments: false,
            min_segment_duration: 0.7,
            max_merge_gap: 0.45,
        }
    }
}

impl CleanupSettings {
    /// No cleanup beyond whitespace and timing repair.
    pub fn minimal() -> Self {
        Self { remove_empty_segments: false, remove_repeated_text: false, merge_short_segments: false, ..Self::default() }
    }
}

pub fn clean(segments: &[Segment], settings: &CleanupSettings) -> Vec<Segment> {
    let mut cleaned: Vec<Segment> = segments.iter().map(|s| Segment::new(s.id, s.start, s.end, normalize_whitespace(&s.text))).collect();

    if settings.remove_repeated_text {
        for s in &mut cleaned {
            s.text = collapse_repeated_text(&s.text);
        }
        cleaned = remove_adjacent_duplicates(cleaned);
        cleaned = remove_echoes_after_silence(cleaned);
    }
    if settings.remove_empty_segments {
        cleaned.retain(|s| !s.text.trim().is_empty());
    }
    if settings.merge_short_segments {
        cleaned = merge_short_segments(cleaned, settings.min_segment_duration, settings.max_merge_gap);
    }
    cleaned = repair_invalid_timings(cleaned, 0.8, 0.05);
    cleaned = repair_long_durations(cleaned, 8.0);
    renumber(cleaned)
}

/// Final pass for a run that may have resumed from saved partials: merge on
/// the time axis first, then clean the whole transcript once so ids are
/// renumbered from 1 and cross-segment passes see the full file.
pub fn clean_resumed(partials: &[Segment], newly_collected: &[Segment], settings: &CleanupSettings) -> Vec<Segment> {
    clean(&chunk_planner::merge_partial_segments(partials, newly_collected), settings)
}

/// Window-local subset of `clean` for streamed batches: per-segment only, no
/// renumbering, no merges, no cross-window dedupe. The full `clean` at
/// completion stays authoritative.
pub fn clean_window(segments: &[Segment], settings: &CleanupSettings) -> Vec<Segment> {
    let mut cleaned: Vec<Segment> = segments.iter().map(|s| Segment::new(s.id, s.start, s.end, normalize_whitespace(&s.text))).collect();
    if settings.remove_repeated_text {
        for s in &mut cleaned {
            s.text = collapse_repeated_text(&s.text);
        }
    }
    if settings.remove_empty_segments {
        cleaned.retain(|s| !s.text.trim().is_empty());
    }
    repair_invalid_timings(cleaned, 0.8, 0.05)
}

/// Cap a cue that a transcriber stretched across silence to roughly the time
/// its text needs to be read.
fn repair_long_durations(segments: Vec<Segment>, maximum: f64) -> Vec<Segment> {
    segments
        .into_iter()
        .map(|mut s| {
            if s.end - s.start > maximum {
                let reading = 0.8 + s.text.chars().count() as f64 * 0.35;
                s.end = s.start + maximum.min(reading.max(1.5));
            }
            s
        })
        .collect()
}

/// Extend zero or near-zero cues to a readable minimum without running into
/// the next cue, unless the next cue starts at or before this one, in which
/// case a brief overlap beats a cue that shows for 0 s.
pub fn repair_invalid_timings(mut segments: Vec<Segment>, minimum: f64, gap_to_next: f64) -> Vec<Segment> {
    for i in 0..segments.len() {
        let (start, end) = (segments[i].start, segments[i].end);
        if end - start >= 0.2 {
            continue;
        }
        let mut new_end = start + minimum;
        if let Some(next) = segments.get(i + 1) {
            let capped = new_end.min(next.start - gap_to_next);
            if capped > start {
                new_end = capped;
            }
        }
        segments[i].end = new_end;
    }
    segments
}

/// Foundation's `.whitespacesAndNewlines` split-and-join.
pub fn normalize_whitespace(text: &str) -> String {
    text.split(char::is_whitespace).filter(|w| !w.is_empty()).collect::<Vec<_>>().join(" ")
}

fn collapse_repeated_text(text: &str) -> String {
    let mut current = normalize_whitespace(text);
    if current.is_empty() {
        return current;
    }
    for _ in 0..10 {
        let next = collapse_repeated_text_pass(&current);
        if next == current {
            break;
        }
        current = next;
    }
    current
}

fn collapse_repeated_text_pass(text: &str) -> String {
    let trimmed = normalize_whitespace(text);
    if trimmed.is_empty() {
        return trimmed;
    }
    let trimmed_len = trimmed.chars().count();
    let words: Vec<&str> = trimmed.split(' ').collect();
    if words.len() >= 4 {
        let max_phrase = 8.min(words.len() / 2);
        for phrase_len in (1..=max_phrase).rev() {
            let mut output: Vec<&str> = Vec::new();
            let mut index = 0;
            while index < words.len() {
                let phrase = &words[index..(index + phrase_len).min(words.len())];
                let mut next = index + phrase_len;
                let mut repeated = false;
                while next + phrase_len <= words.len() && &words[next..next + phrase_len] == phrase {
                    repeated = true;
                    next += phrase_len;
                }
                output.extend_from_slice(phrase);
                index = if repeated { next } else { index + phrase_len };
            }
            let candidate = output.join(" ");
            if candidate.chars().count() < trimmed_len {
                return candidate;
            }
        }
    }

    // Swift iterates Characters (grapheme clusters); for subtitle text the
    // scalar view is close enough and keeps this dependency-free.
    let chars: Vec<char> = trimmed.chars().collect();
    if chars.len() < 8 {
        return trimmed;
    }
    for length in (2..=20.min(chars.len() / 2)).rev() {
        let first = &chars[..length];
        let mut cursor = length;
        let mut repeats = 1;
        while cursor + length <= chars.len() && &chars[cursor..cursor + length] == first {
            repeats += 1;
            cursor += length;
        }
        if repeats >= 2 && cursor == chars.len() {
            return first.iter().collect();
        }
    }
    trimmed
}

fn remove_adjacent_duplicates(segments: Vec<Segment>) -> Vec<Segment> {
    let mut result: Vec<Segment> = Vec::with_capacity(segments.len());
    for s in segments {
        if let Some(last) = result.last_mut() {
            let normalized = comparable_text(&s.text);
            let close_in_time = s.start - last.end <= 0.35;
            if close_in_time && !normalized.is_empty() && normalized == comparable_text(&last.text) {
                last.end = last.end.max(s.end);
                continue;
            }
        }
        result.push(s);
    }
    result
}

fn remove_echoes_after_silence(segments: Vec<Segment>) -> Vec<Segment> {
    let mut result: Vec<Segment> = Vec::with_capacity(segments.len());
    for s in segments {
        if let Some(last) = result.last() {
            if is_likely_silence_echo(&s, last) {
                continue;
            }
        }
        result.push(s);
    }
    result
}

fn is_likely_silence_echo(segment: &Segment, previous: &Segment) -> bool {
    let gap = segment.start - previous.end;
    if gap < 1.5 {
        return false;
    }
    let current = comparable_text(&segment.text);
    let prior = comparable_text(&previous.text);
    let minimum = if gap >= 4.0 { 6 } else { 8 };
    if current.chars().count() < minimum || prior.chars().count() < minimum {
        return false;
    }
    let duration = segment.end - segment.start;
    if current == prior {
        return duration >= 0.8;
    }
    duration >= 1.2 && text_similarity(&current, &prior) >= 0.9
}

/// Lowercased text with whitespace, punctuation and symbols removed.
fn comparable_text(text: &str) -> String {
    text.to_lowercase().chars().filter(|c| !c.is_whitespace() && !is_punctuation_or_symbol(*c)).collect()
}

fn is_punctuation_or_symbol(c: char) -> bool {
    if c.is_ascii() {
        return c.is_ascii_punctuation();
    }
    // Common non-ASCII punctuation and symbols in subtitle text: general
    // punctuation, CJK punctuation, full-width forms, currency, arrows/maths.
    matches!(c as u32,
        0x00A1..=0x00BF | 0x00D7 | 0x00F7 |
        0x2000..=0x206F | 0x20A0..=0x20CF | 0x2100..=0x2BFF |
        0x3000..=0x303F | 0x30FB | 0xFE30..=0xFE4F |
        0xFF01..=0xFF0F | 0xFF1A..=0xFF20 | 0xFF3B..=0xFF40 | 0xFF5B..=0xFF65 |
        0x1F000..=0x1FAFF)
}

fn text_similarity(first: &str, second: &str) -> f64 {
    if first.is_empty() || second.is_empty() {
        return 0.0;
    }
    if first == second {
        return 1.0;
    }
    let a: Vec<char> = first.chars().collect();
    let b: Vec<char> = second.chars().collect();
    let distance = edit_distance(&a, &b);
    1.0 - distance as f64 / a.len().max(b.len()).max(1) as f64
}

fn edit_distance(a: &[char], b: &[char]) -> usize {
    if a.is_empty() {
        return b.len();
    }
    if b.is_empty() {
        return a.len();
    }
    let mut previous: Vec<usize> = (0..=b.len()).collect();
    let mut current = vec![0; b.len() + 1];
    for i in 1..=a.len() {
        current[0] = i;
        for j in 1..=b.len() {
            let cost = usize::from(a[i - 1] != b[j - 1]);
            current[j] = (previous[j] + 1).min(current[j - 1] + 1).min(previous[j - 1] + cost);
        }
        std::mem::swap(&mut previous, &mut current);
    }
    previous[b.len()]
}

fn merge_short_segments(segments: Vec<Segment>, min_duration: f64, max_gap: f64) -> Vec<Segment> {
    let mut result: Vec<Segment> = Vec::with_capacity(segments.len());
    for s in segments {
        if s.end - s.start < min_duration {
            if let Some(last) = result.last_mut() {
                if s.start - last.end <= max_gap {
                    last.end = last.end.max(s.end);
                    last.text = normalize_whitespace(&format!("{} {}", last.text, s.text));
                    continue;
                }
            }
        }
        result.push(s);
    }
    result
}

fn renumber(segments: Vec<Segment>) -> Vec<Segment> {
    segments
        .into_iter()
        .enumerate()
        .map(|(i, mut s)| {
            s.id = i as i64 + 1;
            s
        })
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    fn seg(id: i64, start: f64, end: f64, text: &str) -> Segment {
        Segment::new(id, start, end, text)
    }

    #[test]
    fn zero_duration_segment_with_overlapping_next_is_repaired() {
        let out = repair_invalid_timings(vec![seg(1, 10.0, 10.0, "One"), seg(2, 10.0, 12.0, "Two")], 0.8, 0.05);
        assert!(out[0].end - out[0].start > 0.2);
    }

    #[test]
    fn zero_duration_segment_is_capped_by_next_segment_when_room_exists() {
        let out = repair_invalid_timings(vec![seg(1, 10.0, 10.05, "One"), seg(2, 10.5, 12.0, "Two")], 0.8, 0.05);
        assert!(out[0].end <= 10.5);
        assert!(out[0].end > out[0].start);
    }

    /// Same expectations as the Swift `nativeEngineSegmentsRunThroughSharedCleanupPipeline`.
    #[test]
    fn engine_segments_run_through_shared_cleanup() {
        let raw = vec![seg(1, 0.0, 1.5, "  Hello   world  "), seg(2, 1.55, 3.0, "Hello world"), seg(3, 3.05, 3.05, "   ")];
        let cleaned = clean(&raw, &CleanupSettings::default());
        assert_eq!(cleaned.len(), 1);
        assert_eq!(cleaned[0].text, "Hello world");
        assert_eq!(cleaned[0].id, 1);
        assert_eq!(cleaned[0].start, 0.0);
        assert_eq!(cleaned[0].end, 3.0);
    }

    #[test]
    fn collapses_repeated_phrases_and_character_loops() {
        assert_eq!(collapse_repeated_text("thank you thank you thank you thank you"), "thank you");
        assert_eq!(collapse_repeated_text("hahahahahaha"), "hahaha");
        assert_eq!(collapse_repeated_text("a normal sentence here"), "a normal sentence here");
    }

    #[test]
    fn drops_echo_after_long_silence() {
        let raw = vec![seg(1, 0.0, 2.0, "Where are you going tonight"), seg(2, 6.0, 8.0, "Where are you going tonight?")];
        let cleaned = clean(&raw, &CleanupSettings::default());
        assert_eq!(cleaned.len(), 1);
    }

    #[test]
    fn long_one_word_cue_is_capped_to_reading_time() {
        let cleaned = clean(&[seg(1, 0.0, 30.0, "Hi")], &CleanupSettings::default());
        assert!((cleaned[0].end - 1.5).abs() < 1e-9);
    }

    #[test]
    fn merges_short_segments_when_enabled() {
        let settings = CleanupSettings { merge_short_segments: true, ..CleanupSettings::default() };
        let cleaned = clean(&[seg(1, 0.0, 2.0, "Hello"), seg(2, 2.1, 2.5, "there")], &settings);
        assert_eq!(cleaned.len(), 1);
        assert_eq!(cleaned[0].text, "Hello there");
        assert_eq!(cleaned[0].end, 2.5);
    }

    #[test]
    fn resumed_clean_renumbers_across_saved_and_new_halves() {
        let partials = vec![seg(1, 0.0, 2.0, "First"), seg(2, 2.0, 4.0, "Second")];
        let fresh = vec![seg(1, 4.0, 6.0, "Third")];
        let out = clean_resumed(&partials, &fresh, &CleanupSettings::default());
        assert_eq!(out.iter().map(|s| s.id).collect::<Vec<_>>(), vec![1, 2, 3]);
    }

    #[test]
    fn window_clean_keeps_ids_and_does_not_merge() {
        let out = clean_window(&[seg(7, 0.0, 1.0, " a  b "), seg(8, 1.0, 2.0, "a b")], &CleanupSettings::default());
        assert_eq!(out.len(), 2);
        assert_eq!(out[0].id, 7);
        assert_eq!(out[0].text, "a b");
    }
}
