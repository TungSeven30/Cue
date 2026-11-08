//! "Add from URL": the pure half of the Mac's `MediaDownloadService`.
//! yt-dlp does the fetching; Cue only builds its arguments, reads its
//! progress lines and picks the finished file out of a private staging
//! folder (never by parsing `--print filepath`, which behaves differently
//! across yt-dlp versions).

use crate::watch::is_media;
use std::path::{Path, PathBuf};

/// One progress line, read: a fraction while the transfer reports a
/// percentage, `None` for the indeterminate phases.
#[derive(Debug, Clone, PartialEq)]
pub struct DownloadUpdate {
    pub fraction: Option<f64>,
    pub detail: String,
}

/// Accepts what people paste (whitespace, `<…>`, a bare `youtu.be/…`) and
/// returns an http(s) address, or `None`. File paths are rejected on
/// purpose: they belong on the normal add path.
pub fn normalize_url(text: &str) -> Option<String> {
    let mut trimmed = text.trim();
    if trimmed.starts_with('<') && trimmed.ends_with('>') && trimmed.len() >= 2 {
        trimmed = &trimmed[1..trimmed.len() - 1];
    }
    if trimmed.is_empty() || trimmed.contains(char::is_whitespace) {
        return None;
    }
    if trimmed.starts_with('/') || trimmed.starts_with('~') || trimmed.starts_with('\\') {
        return None;
    }
    // A Windows path such as C:\Videos\clip.mp4.
    let bytes = trimmed.as_bytes();
    if bytes.len() >= 2 && bytes[0].is_ascii_alphabetic() && bytes[1] == b':' && !trimmed.contains("://") {
        return None;
    }
    let lowered = trimmed.to_ascii_lowercase();
    if lowered.contains("://") {
        if !(lowered.starts_with("http://") || lowered.starts_with("https://")) {
            return None;
        }
    } else if let Some(colon) = trimmed.find(':') {
        // No "//": a colon is a scheme (mailto:, magnet:) unless digits
        // follow it, which makes it a port.
        if !trimmed[colon + 1..].starts_with(|c: char| c.is_ascii_digit()) {
            return None;
        }
    }
    let candidate = if lowered.contains("://") { trimmed.to_string() } else { format!("https://{trimmed}") };
    let rest = &candidate[candidate.find("://")? + 3..];
    let authority = rest.split(['/', '?', '#']).next().unwrap_or("");
    let host_port = authority.rsplit('@').next().unwrap_or("");
    let host = host_port.split(':').next().unwrap_or("");
    if !host.contains('.') || host.starts_with('.') || host.ends_with('.') {
        return None;
    }
    Some(candidate)
}

/// yt-dlp's arguments for one page. The output template writes into
/// `staging`, which holds nothing else.
pub fn ytdlp_arguments(url: &str, staging: &Path, ffmpeg: Option<&Path>) -> Vec<String> {
    let mut args: Vec<String> = [
        // One page is one file; a URL that also names a playlist must not
        // quietly queue 200 videos.
        "--no-playlist",
        "--newline",
        "--no-color",
        "--no-part",
        "-f",
        "bv*+ba/b",
        "--merge-output-format",
        "mp4",
    ]
    .into_iter()
    .map(String::from)
    .collect();
    if let Some(ffmpeg) = ffmpeg {
        args.push("--ffmpeg-location".into());
        args.push(ffmpeg.to_string_lossy().into_owned());
    }
    args.push("-o".into());
    // %(title).150B truncates on a byte boundary, so a long CJK title can't
    // make an invalid name.
    args.push(staging.join("%(title).150B.%(ext)s").to_string_lossy().into_owned());
    args.push(url.to_string());
    args
}

/// Reads one yt-dlp stdout line; `None` for lines with nothing to show.
pub fn parse_progress(line: &str) -> Option<DownloadUpdate> {
    let trimmed = line.trim();
    if let Some(body) = trimmed.strip_prefix("[download]") {
        let body = body.trim();
        if let Some(at) = body.find("% of") {
            if let Ok(percent) = body[..at].trim().parse::<f64>() {
                return Some(DownloadUpdate {
                    fraction: Some((percent / 100.0).clamp(0.0, 1.0)),
                    detail: format!("Downloading… {}%", percent as i64),
                });
            }
        }
        if body.starts_with("Destination:") {
            return Some(DownloadUpdate { fraction: Some(0.0), detail: "Downloading…".into() });
        }
        return None;
    }
    if trimmed.starts_with("[Merger]") {
        return Some(DownloadUpdate { fraction: None, detail: "Merging audio and video…".into() });
    }
    None
}

/// The finished file in a staging folder: the largest visible media file.
/// yt-dlp sometimes leaves the pre-merge streams behind, and the merged
/// result is always the biggest.
pub fn finished_media(staging: &Path) -> Option<PathBuf> {
    std::fs::read_dir(staging)
        .ok()?
        .flatten()
        .filter(|e| !e.file_name().to_string_lossy().starts_with('.'))
        .filter(|e| is_media(&e.path()))
        .filter_map(|e| e.metadata().ok().filter(|m| m.is_file()).map(|m| (m.len(), e.path())))
        .max_by_key(|(size, _)| *size)
        .map(|(_, path)| path)
}

/// `clip.mp4`, then `clip-2.mp4`, and so on: a new fetch never overwrites
/// a file an earlier job points at.
pub fn unique_destination(name: &str, dir: &Path) -> PathBuf {
    let candidate = dir.join(name);
    if !candidate.exists() {
        return candidate;
    }
    let path = Path::new(name);
    let base = path.file_stem().map(|s| s.to_string_lossy().into_owned()).unwrap_or_else(|| name.to_string());
    let ext = path.extension().map(|e| e.to_string_lossy().into_owned());
    let named = |suffix: String| match &ext {
        Some(ext) => dir.join(format!("{base}-{suffix}.{ext}")),
        None => dir.join(format!("{base}-{suffix}")),
    };
    (2..1000).map(|n| named(n.to_string())).find(|p| !p.exists()).unwrap_or_else(|| named(uuid::Uuid::new_v4().to_string()))
}

/// The yt-dlp release asset for this platform.
pub fn ytdlp_asset_name() -> &'static str {
    if cfg!(windows) {
        "yt-dlp.exe"
    } else if cfg!(target_os = "macos") {
        "yt-dlp_macos"
    } else {
        "yt-dlp_linux"
    }
}

/// The SHA-256 for `asset` in a release's `SHA2-256SUMS` file.
pub fn checksum_for(sums: &str, asset: &str) -> Option<String> {
    sums.lines().find_map(|line| {
        let mut parts = line.split_whitespace();
        let hash = parts.next()?;
        let name = parts.next()?.trim_start_matches('*');
        (name == asset && hash.len() == 64).then(|| hash.to_ascii_lowercase())
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn urls_are_normalized_like_the_mac() {
        assert_eq!(normalize_url("  youtu.be/abc  ").as_deref(), Some("https://youtu.be/abc"));
        assert_eq!(normalize_url("<https://example.com/v?id=1>").as_deref(), Some("https://example.com/v?id=1"));
        assert_eq!(normalize_url("HTTP://Example.com").as_deref(), Some("HTTP://Example.com"));
        assert_eq!(normalize_url("example.com:8080/x").as_deref(), Some("https://example.com:8080/x"));
        for bad in [
            "",
            "two words.com",
            "/Users/me/clip.mp4",
            "~/clip.mp4",
            "C:\\Videos\\clip.mp4",
            "\\\\server\\share\\clip.mp4",
            "ftp://example.com/a",
            "mailto:me@example.com",
            "magnet:?xt=urn",
            "localhost/a",
            "https://nodot/a",
        ] {
            assert_eq!(normalize_url(bad), None, "{bad}");
        }
    }

    #[test]
    fn progress_lines_are_read() {
        let p = parse_progress("[download]  42.7% of ~ 10.00MiB at 1.00MiB/s ETA 00:05").unwrap();
        assert!((p.fraction.unwrap() - 0.427).abs() < 1e-9);
        assert_eq!(p.detail, "Downloading… 42%");
        assert_eq!(parse_progress("[download] Destination: /tmp/x.mp4").unwrap().fraction, Some(0.0));
        assert_eq!(parse_progress("[Merger] Merging formats into \"x.mp4\"").unwrap().fraction, None);
        assert_eq!(parse_progress("[youtube] abc: Downloading webpage"), None);
        assert_eq!(parse_progress("[download] 100% of 1MiB").unwrap().fraction, Some(1.0));
    }

    #[test]
    fn arguments_match_the_mac() {
        let args = ytdlp_arguments("https://e.com/v", Path::new("/s"), Some(Path::new("/bin/ffmpeg")));
        let joined = args.join(" ");
        assert!(joined.starts_with("--no-playlist --newline --no-color --no-part -f bv*+ba/b --merge-output-format mp4"));
        assert!(joined.contains("--ffmpeg-location /bin/ffmpeg"));
        assert_eq!(args.last().unwrap(), "https://e.com/v");
        assert!(args[args.len() - 2].ends_with("%(title).150B.%(ext)s"));
    }

    #[test]
    fn the_largest_media_file_wins_and_names_never_collide() {
        let dir = tempfile::tempdir().unwrap();
        std::fs::write(dir.path().join("a.f137.mp4"), vec![0; 10]).unwrap();
        std::fs::write(dir.path().join("a.mp4"), vec![0; 30]).unwrap();
        std::fs::write(dir.path().join("a.info.json"), vec![0; 99]).unwrap();
        assert_eq!(finished_media(dir.path()).unwrap(), dir.path().join("a.mp4"));
        assert_eq!(unique_destination("a.mp4", dir.path()), dir.path().join("a-2.mp4"));
        assert_eq!(unique_destination("b.mp4", dir.path()), dir.path().join("b.mp4"));
    }

    #[test]
    fn checksums_are_found_by_asset_name() {
        let h = "a".repeat(64);
        let sums = format!("{} yt-dlp\n{h}  yt-dlp.exe\n", "b".repeat(64));
        assert_eq!(checksum_for(&sums, "yt-dlp.exe"), Some(h));
        assert_eq!(checksum_for(&sums, "yt-dlp_linux"), None);
    }
}
