//! Burning subtitles into an MP4: the pure half of the Mac's
//! `BurnInService`. ffmpeg runs with its working directory set to a fresh
//! temp folder holding `subs.srt`, so the filter string names a fixed
//! relative file and no user text (or a drive letter's colon, which the
//! filter syntax would read as an option separator) ever reaches it.

use serde::Deserialize;
use std::path::{Path, PathBuf};

pub const SUBTITLE_FILE: &str = "subs.srt";

#[derive(Debug, Clone, Copy, PartialEq, Eq, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum TextSize {
    Small,
    Medium,
    Large,
}

/// libass sizes against a PlayResY of 384, so these hold at any resolution.
pub fn force_style(size: TextSize) -> &'static str {
    match size {
        TextSize::Small => "FontSize=14,MarginV=18,BorderStyle=3",
        TextSize::Medium => "FontSize=20,MarginV=22,BorderStyle=3",
        TextSize::Large => "FontSize=27,MarginV=26,BorderStyle=3",
    }
}

/// ffmpeg's arguments. The Mac encodes with VideoToolbox; here it is
/// libx264, which every ffmpeg build with libass also has.
pub fn ffmpeg_arguments(source: &Path, size: TextSize, output: &Path) -> Vec<String> {
    vec![
        "-y".into(),
        "-nostdin".into(),
        "-hide_banner".into(),
        "-i".into(),
        source.to_string_lossy().into_owned(),
        "-vf".into(),
        format!("subtitles=filename={SUBTITLE_FILE}:force_style='{}'", force_style(size)),
        "-c:v".into(),
        "libx264".into(),
        "-preset".into(),
        "veryfast".into(),
        "-crf".into(),
        "20".into(),
        "-c:a".into(),
        "aac".into(),
        "-b:a".into(),
        "192k".into(),
        "-movflags".into(),
        "+faststart".into(),
        output.to_string_lossy().into_owned(),
    ]
}

/// `HH:MM:SS.cc` to seconds.
fn clock(text: &str) -> Option<f64> {
    let mut parts = text.split(':');
    let h: f64 = parts.next()?.trim().parse().ok()?;
    let m: f64 = parts.next()?.trim().parse().ok()?;
    let s: f64 = parts.next()?.trim().parse().ok()?;
    parts.next().is_none().then_some(h * 3600.0 + m * 60.0 + s)
}

/// `time=HH:MM:SS.cc` from an ffmpeg stats line.
pub fn parse_time(line: &str) -> Option<f64> {
    let rest = &line[line.find("time=")? + 5..];
    clock(rest.split_whitespace().next()?)
}

/// `Duration: HH:MM:SS.cc,` from ffmpeg's input banner.
pub fn parse_duration(line: &str) -> Option<f64> {
    let rest = &line[line.find("Duration:")? + 9..];
    clock(rest.split(',').next()?.trim()).filter(|d| *d > 0.0)
}

/// The filter list must include `subtitles`, or this ffmpeg lacks libass
/// and would fail mid-encode.
pub fn has_subtitles_filter(filters_output: &str) -> bool {
    filters_output.contains(" subtitles ")
}

/// `<video>.subtitled.mp4` next to the source, never overwriting anything.
pub fn default_output(source: &Path) -> PathBuf {
    let dir = source.parent().unwrap_or(Path::new("."));
    let base = source.file_stem().map(|s| s.to_string_lossy().into_owned()).unwrap_or_else(|| "video".into());
    crate::download::unique_destination(&format!("{base}.subtitled.mp4"), dir)
}

/// The output must not be the source: Windows paths are case-insensitive,
/// so "Movie.mp4" and "movie.MP4" are one file.
pub fn validate_output(source: &Path, output: &Path) -> Result<(), String> {
    let same = |a: &Path, b: &Path| a.to_string_lossy().to_lowercase() == b.to_string_lossy().to_lowercase();
    let canonical = |p: &Path| std::fs::canonicalize(p).ok();
    if same(source, output) || matches!((canonical(source), canonical(output)), (Some(a), Some(b)) if a == b) {
        return Err("The output file would replace the source video. Choose a different name.".into());
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn styles_match_the_mac() {
        assert_eq!(force_style(TextSize::Small), "FontSize=14,MarginV=18,BorderStyle=3");
        assert_eq!(force_style(TextSize::Large), "FontSize=27,MarginV=26,BorderStyle=3");
        let args = ffmpeg_arguments(Path::new("C:\\v\\a.mp4"), TextSize::Medium, Path::new("C:\\v\\b.mp4"));
        assert!(args.contains(&"subtitles=filename=subs.srt:force_style='FontSize=20,MarginV=22,BorderStyle=3'".to_string()));
        assert_eq!(args.last().unwrap(), "C:\\v\\b.mp4");
    }

    #[test]
    fn stderr_lines_are_read() {
        assert_eq!(parse_time("frame=  10 fps=0.0 q=0.0 size=0kB time=00:01:02.50 bitrate=N/A"), Some(62.5));
        assert_eq!(parse_time("time=N/A"), None);
        assert_eq!(parse_duration("  Duration: 01:00:00.00, start: 0.000000, bitrate: 1 kb/s"), Some(3600.0));
        assert_eq!(parse_duration("  Duration: N/A, bitrate: N/A"), None);
        assert!(has_subtitles_filter(" ... subtitles         V->V       Render text subtitles"));
        assert!(!has_subtitles_filter(" ... scale  V->V"));
    }

    #[test]
    fn output_never_replaces_the_source() {
        let dir = tempfile::tempdir().unwrap();
        let source = dir.path().join("Movie.mp4");
        std::fs::write(&source, b"v").unwrap();
        assert!(validate_output(&source, &dir.path().join("movie.MP4")).is_err());
        assert!(validate_output(&source, &dir.path().join("Movie.subtitled.mp4")).is_ok());
        assert_eq!(default_output(&source), dir.path().join("Movie.subtitled.mp4"));
        std::fs::write(dir.path().join("Movie.subtitled.mp4"), b"v").unwrap();
        assert_eq!(default_output(&source), dir.path().join("Movie.subtitled-2.mp4"));
    }
}
