//! Existing subtitle files beside a video: which ones to adopt and into
//! which slot. Ports `SubtitleSidecarScanner` and
//! `SubtitleImporter.importSidecars` (Sources/Models, Sources/Services).

use super::{read_file, MAX_FILE_SIZE};
use crate::export::{language_suffix, sidecar_language_code};
use crate::segment::Segment;
use std::path::{Path, PathBuf};

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum SidecarSlot {
    Transcript,
    Translation,
}

#[derive(Debug, Clone, PartialEq)]
pub struct SidecarMatch {
    pub path: PathBuf,
    pub slot: SidecarSlot,
}

fn importable(path: &Path) -> bool {
    path.extension().and_then(|e| e.to_str()).is_some_and(|e| e.eq_ignore_ascii_case("srt") || e.eq_ignore_ascii_case("vtt"))
}

fn rank(tag: &str, source_tag: Option<&str>) -> u8 {
    match tag {
        "" => 0,
        "original" => 1,
        t if Some(t) == source_tag => 2,
        _ => 3,
    }
}

/// `<base>.srt` or `<base>.<tag>.srt` only, never fuzzy ("movie (1).srt"
/// belongs to another video), and never the bilingual file. A lone match is
/// the transcript; with several, the target-language tag is the translation
/// and the best remaining one (untagged, "original", the source language,
/// then by name) the transcript.
pub fn match_sidecars(media: &Path, candidates: &[PathBuf], source_language: &str, target_language: &str) -> Vec<SidecarMatch> {
    let base = media.file_stem().map(|s| s.to_string_lossy().to_lowercase()).unwrap_or_default();
    let mut tagged: Vec<(&PathBuf, String)> = Vec::new();
    for candidate in candidates {
        if !importable(candidate) {
            continue;
        }
        let stem = candidate.file_stem().map(|s| s.to_string_lossy().to_lowercase()).unwrap_or_default();
        let tag = if stem == base {
            String::new()
        } else if let Some(tag) = stem.strip_prefix(&format!("{base}.")) {
            tag.to_string()
        } else {
            continue;
        };
        if tag != "bilingual" {
            tagged.push((candidate, tag));
        }
    }
    if tagged.len() <= 1 {
        return tagged.into_iter().map(|(p, _)| SidecarMatch { path: p.clone(), slot: SidecarSlot::Transcript }).collect();
    }
    // The codes the sidecar writer uses, so an export re-imports into the
    // slots it came from.
    let target_tag = sidecar_language_code(target_language).unwrap_or_else(|| language_suffix(target_language));
    let source_tag = sidecar_language_code(source_language);
    let translation = tagged.iter().find(|(_, tag)| *tag == target_tag).map(|(p, _)| (*p).clone());
    let mut remaining: Vec<&(&PathBuf, String)> = tagged.iter().filter(|(p, _)| Some(*p) != translation.as_ref()).collect();
    remaining
        .sort_by(|a, b| (rank(&a.1, source_tag.as_deref()), a.0.file_name()).cmp(&(rank(&b.1, source_tag.as_deref()), b.0.file_name())));
    let Some((transcript, _)) = remaining.first() else {
        return vec![SidecarMatch { path: tagged[0].0.clone(), slot: SidecarSlot::Transcript }];
    };
    let mut matches = vec![SidecarMatch { path: (*transcript).clone(), slot: SidecarSlot::Transcript }];
    if let Some(path) = translation {
        matches.push(SidecarMatch { path, slot: SidecarSlot::Translation });
    }
    matches
}

/// The files in `folder` (not its subfolders), for `match_sidecars`.
pub fn folder_contents(folder: &Path) -> Vec<PathBuf> {
    std::fs::read_dir(folder)
        .map(|entries| {
            entries
                .flatten()
                .filter(|e| e.file_type().is_ok_and(|t| t.is_file()))
                .filter(|e| !e.file_name().to_string_lossy().starts_with('.'))
                .map(|e| e.path())
                .collect()
        })
        .unwrap_or_default()
}

#[derive(Debug, Default)]
pub struct Adopted {
    pub transcript: Option<(PathBuf, Vec<Segment>)>,
    pub translation: Option<(PathBuf, Vec<Segment>)>,
    /// One line per file adopted or skipped, for the job log.
    pub log: Vec<String>,
}

fn file_name(path: &Path) -> String {
    path.file_name().map(|n| n.to_string_lossy().into_owned()).unwrap_or_default()
}

/// Reads one subtitle file for a slot.
pub fn import_file(path: &Path) -> Result<Vec<Segment>, String> {
    read_file(path, MAX_FILE_SIZE).map(|(doc, _)| doc.segments).map_err(|e| e.to_string())
}

/// Reads the matched files. A file that fails is skipped with a log line
/// (a big batch add must not stop on one bad file), and a translation whose
/// transcript failed is dropped too: a translation alone is a state the
/// pipeline cannot represent.
pub fn import_sidecars(media: &Path, candidates: &[PathBuf], source_language: &str, target_language: &str) -> Adopted {
    let mut adopted = Adopted::default();
    for m in match_sidecars(media, candidates, source_language, target_language) {
        match import_file(&m.path) {
            Ok(segments) => {
                adopted.log.push(format!("Loaded subtitles from {} ({} cues).", file_name(&m.path), segments.len()));
                let slot = match m.slot {
                    SidecarSlot::Transcript => &mut adopted.transcript,
                    SidecarSlot::Translation => &mut adopted.translation,
                };
                *slot = Some((m.path, segments));
            }
            Err(e) => adopted.log.push(format!("Could not read {}: {e}", file_name(&m.path))),
        }
    }
    if adopted.transcript.is_none() {
        if let Some((path, _)) = adopted.translation.take() {
            adopted.log.push(format!("Ignored {}: its matching transcript could not be read.", file_name(&path)));
        }
    }
    adopted
}

#[cfg(test)]
mod tests {
    use super::*;

    fn names(matches: &[SidecarMatch]) -> Vec<(String, SidecarSlot)> {
        matches.iter().map(|m| (file_name(&m.path), m.slot)).collect()
    }

    fn paths(names: &[&str]) -> Vec<PathBuf> {
        names.iter().map(|n| PathBuf::from(format!("/v/{n}"))).collect()
    }

    #[test]
    fn matching_follows_the_mac_rules() {
        let media = Path::new("/v/Movie.mkv");
        // A lone file is the transcript whatever its tag.
        assert_eq!(
            names(&match_sidecars(media, &paths(&["Movie.vi.srt"]), "ja", "Vietnamese")),
            [("Movie.vi.srt".into(), SidecarSlot::Transcript)]
        );
        // Exact names only; bilingual and other formats are ignored.
        let none = paths(&["Movie (1).srt", "Movie.bilingual.srt", "Movie.txt", "Other.srt", "Movies.srt"]);
        assert!(match_sidecars(media, &none, "ja", "Vietnamese").is_empty());
        // A Cue export pair goes back where it came from.
        let pair = paths(&["Movie.vi.srt", "Movie.ja.srt", "Movie.bilingual.srt"]);
        assert_eq!(
            names(&match_sidecars(media, &pair, "ja", "Vietnamese")),
            [("Movie.ja.srt".into(), SidecarSlot::Transcript), ("Movie.vi.srt".into(), SidecarSlot::Translation)]
        );
        // Untagged beats "original" beats the source tag beats the rest.
        let ranked = paths(&["movie.fr.srt", "MOVIE.original.vtt", "Movie.srt"]);
        assert_eq!(names(&match_sidecars(media, &ranked, "ja", "German")), [("Movie.srt".into(), SidecarSlot::Transcript)]);
        // A target with no ISO code matches by its suffix.
        let suffix = paths(&["Movie.srt", "Movie.brazilian-portuguese.srt"]);
        assert_eq!(names(&match_sidecars(media, &suffix, "auto", "Brazilian Portuguese"))[1].1, SidecarSlot::Translation);
    }

    #[test]
    fn a_translation_without_a_readable_transcript_is_dropped() {
        let dir = tempfile::tempdir().unwrap();
        let media = dir.path().join("Movie.mp4");
        std::fs::write(dir.path().join("Movie.ja.srt"), "not subtitles").unwrap();
        std::fs::write(dir.path().join("Movie.en.srt"), "1\n00:00:01,000 --> 00:00:02,000\nHello\n").unwrap();
        let adopted = import_sidecars(&media, &folder_contents(dir.path()), "ja", "English");
        assert!(adopted.transcript.is_none() && adopted.translation.is_none());
        assert!(adopted.log[0].starts_with("Could not read Movie.ja.srt"), "{:?}", adopted.log);
        assert_eq!(adopted.log.last().unwrap(), "Ignored Movie.en.srt: its matching transcript could not be read.");

        std::fs::write(dir.path().join("Movie.ja.srt"), "1\n00:00:01,000 --> 00:00:02,000\nこんにちは\n").unwrap();
        let adopted = import_sidecars(&media, &folder_contents(dir.path()), "ja", "English");
        assert_eq!(adopted.transcript.unwrap().1[0].text, "こんにちは");
        assert_eq!(adopted.translation.unwrap().1[0].text, "Hello");
        assert_eq!(adopted.log, ["Loaded subtitles from Movie.ja.srt (1 cues).", "Loaded subtitles from Movie.en.srt (1 cues)."]);
    }
}
