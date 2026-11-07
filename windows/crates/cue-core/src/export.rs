//! Export naming shared by the CLI and the future app. Mirrors
//! `ExportCoordinator.plan`, `languageSuffix` and `sanitizedBaseName`
//! (Sources/Services/ExportCoordinator.swift) so files from either app are
//! named alike: `<base>.<role suffix>.<ext>` when several files are written.

use crate::subtitle::Format;
use crate::Segment;
use std::path::{Path, PathBuf};

/// "Vietnamese" → "vietnamese", "Brazilian Portuguese" → "brazilian-portuguese".
pub fn language_suffix(language: &str) -> String {
    let lowered = language.to_lowercase();
    let parts: Vec<&str> = lowered.split(|c: char| !c.is_alphanumeric()).filter(|p| !p.is_empty()).collect();
    if parts.is_empty() {
        "translation".into()
    } else {
        parts.join("-")
    }
}

pub fn sanitized_base_name(name: &str) -> String {
    let cleaned = name.split(['/', ':', '\\']).collect::<Vec<_>>().join("-").trim().to_string();
    if cleaned.is_empty() {
        "subtitles".into()
    } else {
        cleaned
    }
}

/// The base name for a source file's exports: its stem, sanitized.
pub fn base_name(source: &Path) -> String {
    sanitized_base_name(&source.file_stem().map(|s| s.to_string_lossy().into_owned()).unwrap_or_default())
}

/// `<dir>/<base>.<suffix>.<ext>`, e.g. `movie.translated.vietnamese.srt`.
pub fn document_path(dir: &Path, base: &str, suffix: &str, format: Format) -> PathBuf {
    dir.join(format!("{base}.{suffix}.{}", format.extension()))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn language_suffix_matches_the_mac_app() {
        assert_eq!(language_suffix("Vietnamese"), "vietnamese");
        assert_eq!(language_suffix("Brazilian Portuguese"), "brazilian-portuguese");
        assert_eq!(language_suffix("  "), "translation");
        assert_eq!(language_suffix("Tiếng Việt"), "tiếng-việt");
    }

    #[test]
    fn base_names_drop_path_separators() {
        assert_eq!(sanitized_base_name("a/b:c"), "a-b-c");
        assert_eq!(sanitized_base_name(" "), "subtitles");
        assert_eq!(base_name(Path::new("C:/x/Movie 01.mkv")), "Movie 01");
        assert_eq!(
            document_path(Path::new("out"), "movie", "translated.vietnamese", Format::Srt),
            Path::new("out").join("movie.translated.vietnamese.srt")
        );
    }
}

/// `ExportCoordinator.sidecarLanguageCode`: a short code for the ten
/// languages the Mac maps, `None` for auto/empty or anything else.
pub fn sidecar_language_code(language: &str) -> Option<String> {
    const CODES: [(&str, &str); 10] = [
        ("english", "en"),
        ("japanese", "ja"),
        ("chinese", "zh"),
        ("korean", "ko"),
        ("spanish", "es"),
        ("french", "fr"),
        ("german", "de"),
        ("indonesian", "id"),
        ("thai", "th"),
        ("vietnamese", "vi"),
    ];
    let normalized = language.trim().to_lowercase();
    if normalized.is_empty() || normalized == "auto" {
        return None;
    }
    if CODES.iter().any(|(_, code)| *code == normalized) {
        return Some(normalized);
    }
    CODES.iter().find(|(name, _)| *name == normalized).map(|(_, code)| code.to_string())
}

pub struct SidecarSet<'a> {
    pub transcript: &'a [Segment],
    pub translation: &'a [Segment],
    pub source_language: &'a str,
    pub target_language: &'a str,
    pub include_original: bool,
    pub include_translation: bool,
    pub include_bilingual: bool,
}

/// `ExportCoordinator.writeSidecars`: SRT files next to the video, named
/// `<base>.<code>.srt`, `<base>.<code|suffix>.srt` and `<base>.bilingual.srt`.
/// An existing file gets a one-time `.bak` copy before it is replaced.
pub fn write_sidecars(source: &Path, set: &SidecarSet) -> Result<Vec<PathBuf>, String> {
    let folder = source.parent().unwrap_or(Path::new("."));
    let base = source.file_stem().map(|s| s.to_string_lossy().into_owned()).unwrap_or_else(|| "subtitles".into());
    let mut documents: Vec<(String, Vec<Segment>)> = Vec::new();
    if set.include_original && !set.transcript.is_empty() {
        let code = sidecar_language_code(set.source_language).unwrap_or_else(|| "original".into());
        documents.push((format!("{base}.{code}.srt"), set.transcript.to_vec()));
    }
    if set.include_translation && !set.translation.is_empty() {
        let code = sidecar_language_code(set.target_language).unwrap_or_else(|| language_suffix(set.target_language));
        documents.push((format!("{base}.{code}.srt"), set.translation.to_vec()));
    }
    if set.include_bilingual && !set.transcript.is_empty() && !set.translation.is_empty() {
        documents.push((format!("{base}.bilingual.srt"), crate::translation::bilingual_segments(set.transcript, set.translation)));
    }
    let mut written = Vec::new();
    for (name, segments) in documents {
        let path = folder.join(name);
        back_up_existing(&path).map_err(|e| format!("cannot back up {}: {e}", path.display()))?;
        crate::subtitle::write_file(&segments, Format::Srt, &path).map_err(|e| format!("cannot write {}: {e}", path.display()))?;
        written.push(path);
    }
    Ok(written)
}

fn back_up_existing(path: &Path) -> std::io::Result<()> {
    if !path.exists() {
        return Ok(());
    }
    let mut backup = path.as_os_str().to_owned();
    backup.push(".bak");
    let backup = PathBuf::from(backup);
    if backup.exists() {
        return Ok(());
    }
    std::fs::copy(path, backup).map(|_| ())
}

#[cfg(test)]
mod sidecar_tests {
    use super::*;

    #[test]
    fn sidecars_follow_mac_names_and_back_up_once() {
        let dir = tempfile::tempdir().unwrap();
        let video = dir.path().join("Movie.mkv");
        let transcript = vec![Segment::new(1, 0.0, 1.0, "hola")];
        let translation = vec![Segment::new(1, 0.0, 1.0, "hello")];
        let set = SidecarSet {
            transcript: &transcript,
            translation: &translation,
            source_language: "es",
            target_language: "English",
            include_original: true,
            include_translation: true,
            include_bilingual: true,
        };
        let names: Vec<String> =
            write_sidecars(&video, &set).unwrap().iter().map(|p| p.file_name().unwrap().to_string_lossy().into_owned()).collect();
        assert_eq!(names, ["Movie.es.srt", "Movie.en.srt", "Movie.bilingual.srt"]);
        std::fs::write(dir.path().join("Movie.en.srt"), "mine").unwrap();
        write_sidecars(&video, &set).unwrap();
        write_sidecars(&video, &set).unwrap();
        assert_eq!(std::fs::read_to_string(dir.path().join("Movie.en.srt.bak")).unwrap(), "mine");
        assert_eq!(sidecar_language_code("auto"), None);
        assert_eq!(sidecar_language_code("Brazilian Portuguese"), None);
    }
}
