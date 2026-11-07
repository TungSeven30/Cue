//! Export naming shared by the CLI and the future app. Mirrors
//! `ExportCoordinator.plan`, `languageSuffix` and `sanitizedBaseName`
//! (Sources/Services/ExportCoordinator.swift) so files from either app are
//! named alike: `<base>.<role suffix>.<ext>` when several files are written.

use crate::subtitle::Format;
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
