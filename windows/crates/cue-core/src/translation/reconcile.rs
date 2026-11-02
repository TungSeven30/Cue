//! Mirrors `TranslationReconciliation.alignedTranslations`
//! (Sources/Services/TranslationReconciliation.swift): an existing
//! translation (an imported file, or a manifest from an earlier run) is
//! matched to the transcript by its exact millisecond timing, and only where
//! that match is unambiguous.

use crate::subtitle::MAX_TIMESTAMP_SECONDS;
use crate::Segment;
use std::collections::HashMap;

fn timing_key(segment: &Segment) -> Option<(i64, i64)> {
    let (start, end) = (segment.start, segment.end);
    if !start.is_finite() || !end.is_finite() || start < 0.0 || end < start || end >= MAX_TIMESTAMP_SECONDS {
        return None;
    }
    Some(((start * 1000.0).round() as i64, (end * 1000.0).round() as i64))
}

pub fn aligned_translations(translated: &[Segment], source: &[Segment]) -> Vec<Segment> {
    let mut by_timing: HashMap<(i64, i64), Vec<&Segment>> = HashMap::new();
    for segment in source {
        if let Some(key) = timing_key(segment) {
            by_timing.entry(key).or_default().push(segment);
        }
    }
    let mut matches: HashMap<i64, Vec<Segment>> = HashMap::new();
    for segment in translated {
        let Some(key) = timing_key(segment) else { continue };
        let Some(candidates) = by_timing.get(&key) else { continue };
        if candidates.len() != 1 {
            continue;
        }
        let original = candidates[0];
        matches.entry(original.id).or_default().push(Segment::new(original.id, original.start, original.end, segment.text.clone()));
    }
    source
        .iter()
        .filter_map(|original| match matches.get(&original.id) {
            Some(list) if list.len() == 1 => Some(list[0].clone()),
            _ => None,
        })
        .collect()
}

/// The stacked bilingual document: source line, then its translation, on
/// every cue. Mirrors `ExportCoordinator.bilingualSegments`.
pub fn bilingual_segments(transcript: &[Segment], translated: &[Segment]) -> Vec<Segment> {
    let aligned = aligned_translations(translated, transcript);
    let mut by_id: HashMap<i64, String> = HashMap::new();
    for segment in aligned {
        by_id.entry(segment.id).or_insert(segment.text);
    }
    transcript
        .iter()
        .map(|s| Segment::new(s.id, s.start, s.end, format!("{}\n{}", s.text, by_id.get(&s.id).map(String::as_str).unwrap_or(""))))
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn aligns_by_exact_millisecond_timing() {
        let source = vec![Segment::new(1, 0.0, 1.0, "hello"), Segment::new(2, 1.0, 2.0, "world")];
        let translated = vec![Segment::new(7, 1.0004, 2.0, "monde"), Segment::new(8, 5.0, 6.0, "stray")];
        let aligned = aligned_translations(&translated, &source);
        assert_eq!(aligned, vec![Segment::new(2, 1.0, 2.0, "monde")]);
    }

    #[test]
    fn ambiguous_timings_are_dropped() {
        let source = vec![Segment::new(1, 0.0, 1.0, "a"), Segment::new(2, 0.0, 1.0, "b")];
        let translated = vec![Segment::new(1, 0.0, 1.0, "x")];
        assert!(aligned_translations(&translated, &source).is_empty());
        let source = vec![Segment::new(1, 0.0, 1.0, "a")];
        let translated = vec![Segment::new(1, 0.0, 1.0, "x"), Segment::new(2, 0.0, 1.0, "y")];
        assert!(aligned_translations(&translated, &source).is_empty());
    }

    #[test]
    fn bilingual_stacks_source_over_translation() {
        let source = vec![Segment::new(1, 0.0, 1.0, "hello"), Segment::new(2, 1.0, 2.0, "world")];
        let translated = vec![Segment::new(1, 0.0, 1.0, "bonjour")];
        let stacked = bilingual_segments(&source, &translated);
        assert_eq!(stacked[0].text, "hello\nbonjour");
        assert_eq!(stacked[1].text, "world\n");
    }
}
