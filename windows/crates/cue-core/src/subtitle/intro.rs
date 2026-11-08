//! The intro summary as opening cues. Ports
//! `SubtitleWriter.segmentsPrependingIntro` and `introCueTexts`.

use crate::segment::Segment;
use unicode_segmentation::UnicodeSegmentation;

fn length(text: &str) -> usize {
    text.graphemes(true).count()
}

/// Splits a summary into screen-sized pieces on sentence boundaries,
/// packing sentences together while they fit. A short summary stays whole.
pub fn intro_cue_texts(summary: &str, limit: usize) -> Vec<String> {
    if length(summary) <= limit {
        return vec![summary.to_string()];
    }
    let sentences: Vec<&str> = summary.split_sentence_bounds().map(str::trim).filter(|s| !s.is_empty()).collect();
    if sentences.is_empty() {
        return vec![summary.to_string()];
    }
    let mut chunks = Vec::new();
    let mut current = String::new();
    for sentence in sentences {
        if current.is_empty() {
            current = sentence.to_string();
        } else if length(&current) + 1 + length(sentence) <= limit {
            current.push(' ');
            current.push_str(sentence);
        } else {
            chunks.push(std::mem::replace(&mut current, sentence.to_string()));
        }
    }
    if !current.is_empty() {
        chunks.push(current);
    }
    chunks
}

/// The summary as cues at the very start, then the subtitles renumbered
/// after them. A short summary holds until the first line (3 to 10 s); a
/// long one runs as a sequence, each piece held for its reading time, and
/// may overlap a fast cold open rather than be lost to it.
pub fn segments_prepending_intro(summary: Option<&str>, segments: &[Segment]) -> Vec<Segment> {
    let Some(summary) = summary.map(str::trim).filter(|s| !s.is_empty()) else {
        return segments.to_vec();
    };
    let chunks = intro_cue_texts(summary, 220);
    let mut intro = Vec::new();
    if chunks.len() == 1 {
        let end = segments.first().map(|s| s.start.clamp(3.0, 10.0)).unwrap_or(8.0);
        intro.push(Segment::new(1, 0.0, end, chunks[0].clone()));
    } else {
        let mut cursor = 0.0;
        for (index, chunk) in chunks.into_iter().enumerate() {
            let duration = (length(&chunk) as f64 * 0.055).clamp(3.5, 8.0);
            intro.push(Segment::new(index as i64 + 1, cursor, cursor + duration, chunk));
            cursor += duration;
        }
    }
    let offset = intro.len() as i64;
    intro.extend(segments.iter().enumerate().map(|(i, s)| Segment::new(i as i64 + offset + 1, s.start, s.end, s.text.clone())));
    intro
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_short_summary_is_one_cue_until_the_first_line() {
        let subs = vec![Segment::new(7, 12.0, 14.0, "Hi")];
        let out = segments_prepending_intro(Some("  A quiet town. "), &subs);
        assert_eq!(out[0], Segment::new(1, 0.0, 10.0, "A quiet town."));
        assert_eq!(out[1], Segment::new(2, 12.0, 14.0, "Hi"));
        let early = segments_prepending_intro(Some("x"), &[Segment::new(1, 1.0, 2.0, "a")]);
        assert_eq!(early[0].end, 3.0);
        assert_eq!(segments_prepending_intro(Some("x"), &[])[0].end, 8.0);
        assert_eq!(segments_prepending_intro(Some("  "), &subs), subs);
        assert_eq!(segments_prepending_intro(None, &subs), subs);
    }

    #[test]
    fn a_long_summary_becomes_a_sequence_packed_by_sentence() {
        let sentence = "This sentence has exactly sixty characters in it, roughly ok.";
        let summary = [sentence; 6].join(" ");
        let chunks = intro_cue_texts(&summary, 220);
        assert_eq!(chunks.len(), 2);
        assert!(chunks.iter().all(|c| length(c) <= 220));
        assert_eq!(chunks.join(" "), summary);

        let out = segments_prepending_intro(Some(&summary), &[Segment::new(1, 1.0, 2.0, "a")]);
        assert_eq!(out.len(), 3);
        assert_eq!(out[0].start, 0.0);
        assert!((out[0].end - 8.0).abs() < 1e-9, "a long piece is held for the 8 s cap");
        assert_eq!(out[1].start, out[0].end);
        assert_eq!(out[2].id, 3);
    }

    #[test]
    fn one_unbroken_run_stays_whole() {
        let blob = "x".repeat(300);
        assert_eq!(intro_cue_texts(&blob, 220), vec![blob]);
    }
}
