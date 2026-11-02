//! Audio extraction and loading.
//!
//! The macOS app decodes with AVFoundation and falls back to ffmpeg. Windows
//! has no equivalent that reads MKV, so ffmpeg is the only route: the
//! installer ships `ffmpeg.exe` next to `cue.exe`. Output is the same 16 kHz
//! mono 16-bit PCM WAV every engine expects, cached by source path, size and
//! modification time so re-runs skip extraction (capped at 10 GB, like macOS).

use sha2::{Digest, Sha256};
use std::io::{BufRead, BufReader};
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::sync::atomic::{AtomicBool, Ordering};
use std::time::{Duration, SystemTime};

pub const SAMPLE_RATE: usize = 16_000;
pub const CACHE_LIMIT_BYTES: u64 = 10 * 1024 * 1024 * 1024;

#[derive(Debug, thiserror::Error)]
pub enum AudioError {
    #[error("ffmpeg was not found. Reinstall Cue, or put ffmpeg.exe next to cue.exe or on PATH.")]
    FfmpegMissing,
    #[error("ffmpeg could not read the audio: {0}")]
    FfmpegFailed(String),
    #[error("Canceled.")]
    Canceled,
    #[error("Invalid WAV file: {0}")]
    InvalidWav(String),
    #[error(transparent)]
    Io(#[from] std::io::Error),
}

/// Locate ffmpeg: `CUE_FFMPEG`, then next to the running executable, then PATH.
pub fn find_ffmpeg() -> Option<PathBuf> {
    let exe_name = if cfg!(windows) { "ffmpeg.exe" } else { "ffmpeg" };
    if let Some(p) = std::env::var_os("CUE_FFMPEG").map(PathBuf::from).filter(|p| p.is_file()) {
        return Some(p);
    }
    if let Some(p) = std::env::current_exe().ok().and_then(|e| e.parent().map(|d| d.join(exe_name))).filter(|p| p.is_file()) {
        return Some(p);
    }
    std::env::var_os("PATH").and_then(|paths| std::env::split_paths(&paths).map(|d| d.join(exe_name)).find(|p| p.is_file()))
}

/// Hide the console window ffmpeg would otherwise flash on Windows.
pub fn background_command(program: &Path) -> Command {
    #[allow(unused_mut)]
    let mut cmd = Command::new(program);
    #[cfg(windows)]
    {
        use std::os::windows::process::CommandExt;
        const CREATE_NO_WINDOW: u32 = 0x0800_0000;
        cmd.creation_flags(CREATE_NO_WINDOW);
    }
    cmd
}

/// Cache file for `source`: keyed by canonical path, size and mtime, so an
/// edited or replaced file is re-extracted.
pub fn cached_wav_path(source: &Path, cache_dir: &Path) -> std::io::Result<PathBuf> {
    let canonical = std::fs::canonicalize(source)?;
    let meta = std::fs::metadata(&canonical)?;
    let mtime = meta.modified().ok().and_then(|t| t.duration_since(SystemTime::UNIX_EPOCH).ok()).unwrap_or_default();
    let mut hasher = Sha256::new();
    hasher.update(canonical.to_string_lossy().as_bytes());
    hasher.update(meta.len().to_le_bytes());
    hasher.update(mtime.as_nanos().to_le_bytes());
    Ok(cache_dir.join(format!("{}.wav", &hex::encode(hasher.finalize())[..32])))
}

/// Extract `source` to a cached WAV, reusing a previous extraction.
/// `on_progress` gets 0–1 when ffmpeg reports a known duration.
pub fn extract_cached(
    source: &Path,
    cache_dir: &Path,
    cancel: &AtomicBool,
    on_progress: &mut dyn FnMut(f64),
) -> Result<(PathBuf, bool), AudioError> {
    std::fs::create_dir_all(cache_dir)?;
    let wav = cached_wav_path(source, cache_dir)?;
    if std::fs::metadata(&wav).map(|m| m.len() > 44).unwrap_or(false) {
        return Ok((wav, true));
    }
    let ffmpeg = find_ffmpeg().ok_or(AudioError::FfmpegMissing)?;
    extract_with_ffmpeg(&ffmpeg, source, &wav, cancel, on_progress)?;
    prune_cache(cache_dir, &wav, CACHE_LIMIT_BYTES);
    Ok((wav, false))
}

pub fn extract_with_ffmpeg(
    ffmpeg: &Path,
    source: &Path,
    destination: &Path,
    cancel: &AtomicBool,
    on_progress: &mut dyn FnMut(f64),
) -> Result<(), AudioError> {
    let temp = destination.with_extension(format!("partial-{}", std::process::id()));
    let mut child = background_command(ffmpeg)
        .args(["-y", "-nostdin", "-hide_banner", "-loglevel", "error", "-progress", "pipe:1", "-i"])
        .arg(source)
        .args(["-vn", "-acodec", "pcm_s16le", "-ar", "16000", "-ac", "1", "-f", "wav"])
        .arg(&temp)
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .map_err(|e| AudioError::FfmpegFailed(format!("could not start ffmpeg: {e}")))?;

    // Stderr is drained on its own thread so a chatty ffmpeg never blocks.
    let stderr = child.stderr.take().expect("piped");
    let stderr_thread = std::thread::spawn(move || {
        let mut last = String::new();
        for line in BufReader::new(stderr).lines().map_while(Result::ok) {
            if !line.trim().is_empty() {
                last = line;
            }
        }
        last
    });

    let total = probe_duration(ffmpeg, source);
    let stdout = child.stdout.take().expect("piped");
    for line in BufReader::new(stdout).lines().map_while(Result::ok) {
        if cancel.load(Ordering::Relaxed) {
            let _ = child.kill();
            let _ = child.wait();
            let _ = std::fs::remove_file(&temp);
            return Err(AudioError::Canceled);
        }
        if let (Some(total), Some(us)) = (total, line.strip_prefix("out_time_us=").and_then(|v| v.parse::<f64>().ok())) {
            if total > 0.0 {
                on_progress((us / 1_000_000.0 / total).clamp(0.0, 1.0));
            }
        }
    }
    let status = child.wait()?;
    let last = stderr_thread.join().unwrap_or_default();
    if cancel.load(Ordering::Relaxed) {
        let _ = std::fs::remove_file(&temp);
        return Err(AudioError::Canceled);
    }
    if !status.success() {
        let _ = std::fs::remove_file(&temp);
        return Err(AudioError::FfmpegFailed(if last.is_empty() { format!("ffmpeg exited with {status}") } else { last }));
    }
    std::fs::rename(&temp, destination)?;
    on_progress(1.0);
    Ok(())
}

/// Duration in seconds from ffmpeg's banner (no ffprobe needed).
fn probe_duration(ffmpeg: &Path, source: &Path) -> Option<f64> {
    let out = background_command(ffmpeg)
        .args(["-hide_banner", "-nostdin", "-i"])
        .arg(source)
        .stdout(Stdio::null())
        .stderr(Stdio::piped())
        .output()
        .ok()?;
    parse_ffmpeg_duration(&String::from_utf8_lossy(&out.stderr))
}

pub fn parse_ffmpeg_duration(banner: &str) -> Option<f64> {
    let rest = banner.split("Duration: ").nth(1)?;
    let stamp = rest.split(',').next()?.trim();
    let parts: Vec<f64> = stamp.split(':').map(|p| p.parse().ok()).collect::<Option<_>>()?;
    (parts.len() == 3).then(|| parts[0] * 3600.0 + parts[1] * 60.0 + parts[2])
}

/// Delete least-recently-modified WAVs until the cache fits `limit`, never
/// touching the one just produced.
pub fn prune_cache(dir: &Path, keep: &Path, limit: u64) {
    let Ok(entries) = std::fs::read_dir(dir) else { return };
    let mut files: Vec<(PathBuf, u64, SystemTime)> = entries
        .filter_map(Result::ok)
        .filter(|e| e.path().extension().is_some_and(|x| x == "wav"))
        .filter_map(|e| {
            let m = e.metadata().ok()?;
            Some((e.path(), m.len(), m.modified().unwrap_or(SystemTime::UNIX_EPOCH)))
        })
        .collect();
    let mut total: u64 = files.iter().map(|f| f.1).sum();
    files.sort_by_key(|f| f.2);
    for (path, len, _) in files {
        if total <= limit {
            break;
        }
        if path == keep {
            continue;
        }
        if std::fs::remove_file(&path).is_ok() {
            total -= len;
        }
    }
}

/// Load a 16 kHz mono 16-bit PCM WAV as floats in [-1, 1].
pub fn load_pcm16_mono(path: &Path) -> Result<Vec<f32>, AudioError> {
    let reader = hound::WavReader::open(path).map_err(|e| AudioError::InvalidWav(e.to_string()))?;
    let spec = reader.spec();
    if spec.channels != 1
        || spec.sample_rate as usize != SAMPLE_RATE
        || spec.bits_per_sample != 16
        || spec.sample_format != hound::SampleFormat::Int
    {
        return Err(AudioError::InvalidWav(format!(
            "expected 16 kHz mono 16-bit PCM, got {} Hz, {} channel(s), {} bits",
            spec.sample_rate, spec.channels, spec.bits_per_sample
        )));
    }
    reader.into_samples::<i16>().map(|s| s.map(|v| v as f32 / 32_768.0).map_err(|e| AudioError::InvalidWav(e.to_string()))).collect()
}

/// For progress text: "1:02:03" / "2:03".
pub fn format_duration(d: Duration) -> String {
    let s = d.as_secs();
    if s >= 3600 {
        format!("{}:{:02}:{:02}", s / 3600, (s % 3600) / 60, s % 60)
    } else {
        format!("{}:{:02}", s / 60, s % 60)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_ffmpeg_banner_duration() {
        let banner = "Input #0, matroska,webm, from 'a.mkv':\n  Duration: 01:02:03.50, start: 0.000000, bitrate: 1 kb/s";
        assert_eq!(parse_ffmpeg_duration(banner), Some(3723.5));
        assert_eq!(parse_ffmpeg_duration("Duration: N/A, start"), None);
    }

    #[test]
    fn loads_pcm_and_rejects_wrong_format() {
        let dir = tempfile::tempdir().unwrap();
        let ok = dir.path().join("ok.wav");
        let spec = hound::WavSpec { channels: 1, sample_rate: 16_000, bits_per_sample: 16, sample_format: hound::SampleFormat::Int };
        let mut w = hound::WavWriter::create(&ok, spec).unwrap();
        for v in [0i16, 16_384, -32_768] {
            w.write_sample(v).unwrap();
        }
        w.finalize().unwrap();
        assert_eq!(load_pcm16_mono(&ok).unwrap(), vec![0.0, 0.5, -1.0]);

        let stereo = dir.path().join("stereo.wav");
        let mut w = hound::WavWriter::create(&stereo, hound::WavSpec { channels: 2, ..spec }).unwrap();
        w.write_sample(0i16).unwrap();
        w.write_sample(0i16).unwrap();
        w.finalize().unwrap();
        assert!(matches!(load_pcm16_mono(&stereo), Err(AudioError::InvalidWav(_))));
    }

    #[test]
    fn cache_key_changes_when_file_changes() {
        let dir = tempfile::tempdir().unwrap();
        let src = dir.path().join("a.mp4");
        std::fs::write(&src, b"one").unwrap();
        let first = cached_wav_path(&src, dir.path()).unwrap();
        std::fs::write(&src, b"longer").unwrap();
        assert_ne!(first, cached_wav_path(&src, dir.path()).unwrap());
    }

    #[test]
    fn prune_keeps_newest_and_the_protected_file() {
        let dir = tempfile::tempdir().unwrap();
        let old = dir.path().join("old.wav");
        let keep = dir.path().join("keep.wav");
        std::fs::write(&old, vec![0u8; 100]).unwrap();
        std::thread::sleep(Duration::from_millis(20));
        std::fs::write(&keep, vec![0u8; 100]).unwrap();
        prune_cache(dir.path(), &keep, 150);
        assert!(!old.exists());
        assert!(keep.exists());
    }

    #[test]
    fn extracts_with_real_ffmpeg_when_available() {
        let Some(ffmpeg) = find_ffmpeg() else { return };
        let dir = tempfile::tempdir().unwrap();
        let src = dir.path().join("tone.mkv");
        let ok = background_command(&ffmpeg)
            .args(["-y", "-loglevel", "error", "-f", "lavfi", "-i", "sine=frequency=440:duration=2", "-c:a", "flac"])
            .arg(&src)
            .status()
            .unwrap()
            .success();
        assert!(ok);
        let cancel = AtomicBool::new(false);
        let mut last = 0.0;
        let (wav, cached) = extract_cached(&src, &dir.path().join("cache"), &cancel, &mut |f| last = f).unwrap();
        assert!(!cached);
        assert_eq!(last, 1.0);
        let samples = load_pcm16_mono(&wav).unwrap();
        assert!((samples.len() as i64 - 32_000).abs() < 400, "got {}", samples.len());
        let (_, cached) = extract_cached(&src, &dir.path().join("cache"), &cancel, &mut |_| {}).unwrap();
        assert!(cached);
    }
}
