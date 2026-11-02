use super::Format;
use crate::segment::Segment;
use regex::Regex;
use std::io;
use std::path::Path;
use std::sync::LazyLock;

/// Render segments in `format`. Output is byte-identical to the macOS
/// writer for SRT, WebVTT, text and Markdown (LF line endings, UTF-8 without
/// BOM, which every Windows player reads).
pub fn render(segments: &[Segment], format: Format) -> String {
    match format {
        Format::Srt => {
            let body: Vec<String> = segments
                .iter()
                .map(|s| {
                    format!(
                        "{}\n{} --> {}\n{}",
                        s.id,
                        format_srt_timestamp(s.start),
                        format_srt_timestamp(s.end),
                        sanitized_cue_text(&s.text)
                    )
                })
                .collect();
            body.join("\n\n") + "\n"
        }
        Format::Vtt => {
            let body: Vec<String> = segments
                .iter()
                .map(|s| {
                    format!(
                        "{}\n{} --> {}\n{}",
                        s.id,
                        format_vtt_timestamp(s.start),
                        format_vtt_timestamp(s.end),
                        sanitized_cue_text(&s.text)
                    )
                })
                .collect();
            format!("WEBVTT\n\n{}\n", body.join("\n\n"))
        }
        Format::Text => {
            let lines: Vec<&str> = segments.iter().map(|s| s.text.trim()).filter(|t| !t.is_empty()).collect();
            lines.join("\n") + "\n"
        }
        Format::Markdown => {
            let lines: Vec<String> = segments
                .iter()
                .map(|s| {
                    let single = sanitized_cue_text(&s.text).replace('\n', " / ");
                    format!("- `{} - {}` {}", format_display_timestamp(s.start), format_display_timestamp(s.end), single)
                })
                .collect();
            lines.join("\n") + "\n"
        }
        Format::Json => serde_json::to_string_pretty(segments).expect("segments always serialize") + "\n",
    }
}

/// Write atomically: a temp file next to the target, then rename, so a
/// player or a crash never sees a half-written subtitle.
pub fn write_file(segments: &[Segment], format: Format, path: &Path) -> io::Result<()> {
    let contents = render(segments, format);
    let dir = path.parent().filter(|p| !p.as_os_str().is_empty()).unwrap_or(Path::new("."));
    let name = path.file_name().map(|n| n.to_string_lossy().into_owned()).unwrap_or_else(|| "subtitle".into());
    let temp = dir.join(format!(".{name}.cue-partial-{}", std::process::id()));
    std::fs::write(&temp, contents)?;
    std::fs::rename(&temp, path).inspect_err(|_| {
        let _ = std::fs::remove_file(&temp);
    })
}

/// A blank line ends a cue in SRT/VTT, so runs of newlines (often from LLM
/// translations) collapse to one line break; intentional two-line cues survive.
pub fn sanitized_cue_text(text: &str) -> String {
    let mut s = text.replace("\r\n", "\n").replace('\r', "\n");
    while s.contains("\n\n") {
        s = s.replace("\n\n", "\n");
    }
    s.trim().to_string()
}

static TAGS: LazyLock<Regex> = LazyLock::new(|| Regex::new(r"</?(?:b|i|u|c|v|lang|ruby|rt|font)(?:[ \t.][^<>]*)?>").unwrap());
static KARAOKE: LazyLock<Regex> = LazyLock::new(|| Regex::new(r"<(?:\d+:)?\d{2}:\d{2}\.\d{3}>").unwrap());
static ENTITY: LazyLock<Regex> = LazyLock::new(|| Regex::new(r"&(?:amp|lt|gt|nbsp|lrm|rlm|quot|apos|#[0-9]+|#x[0-9a-fA-F]+);").unwrap());

/// Display-only text: strips supported markup and decodes entities once.
pub fn plain_cue_text(text: &str) -> String {
    let without_tags = TAGS.replace_all(text, "");
    let without_tags = KARAOKE.replace_all(&without_tags, "");
    ENTITY
        .replace_all(&without_tags, |caps: &regex::Captures| {
            let whole = &caps[0];
            let entity = &whole[1..whole.len() - 1];
            let named = match entity {
                "amp" => Some("&".to_string()),
                "lt" => Some("<".into()),
                "gt" => Some(">".into()),
                "nbsp" => Some("\u{00A0}".into()),
                "lrm" => Some("\u{200E}".into()),
                "rlm" => Some("\u{200F}".into()),
                "quot" => Some("\"".into()),
                "apos" => Some("'".into()),
                _ => None,
            };
            if let Some(n) = named {
                return n;
            }
            let numeric = if let Some(hex) = entity.strip_prefix("#x") {
                u32::from_str_radix(hex, 16).ok()
            } else {
                entity.strip_prefix('#').and_then(|d| d.parse::<u32>().ok())
            };
            numeric.filter(|v| *v != 0).and_then(char::from_u32).map(String::from).unwrap_or_else(|| whole.to_string())
        })
        .into_owned()
}

/// Clamp to [0, just under 100 h]; NaN becomes 0. A bad cue never panics.
fn clamped(seconds: f64) -> f64 {
    if seconds.is_nan() {
        0.0
    } else {
        seconds.clamp(0.0, 359_999.999)
    }
}

/// `HH:MM:SS,mmm`, rounded to whole milliseconds with carry.
pub fn format_srt_timestamp(seconds: f64) -> String {
    let total_ms = (clamped(seconds) * 1000.0).round() as u64;
    let ms = total_ms % 1000;
    let total_s = total_ms / 1000;
    format!("{:02}:{:02}:{:02},{:03}", total_s / 3600, (total_s % 3600) / 60, total_s % 60, ms)
}

pub fn format_vtt_timestamp(seconds: f64) -> String {
    format_srt_timestamp(seconds).replace(',', ".")
}

pub fn format_display_timestamp(seconds: f64) -> String {
    let c = clamped(seconds);
    let whole = c as u64;
    format!("{:02}:{:02}:{:02}", whole / 3600, (whole % 3600) / 60, whole % 60)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn seg(id: i64, start: f64, end: f64, text: &str) -> Segment {
        Segment::new(id, start, end, text)
    }

    #[test]
    fn plain_preview_decodes_entities_once_and_keeps_literal_brackets() {
        assert_eq!(plain_cue_text("2 < 3 &amp;lt; &#x1F600;"), "2 < 3 &lt; 😀");
        assert_eq!(plain_cue_text("<c.green>Việt</c><00:01.000> Nam"), "Việt Nam");
        assert_eq!(plain_cue_text("&#xD800; &unknown;"), "&#xD800; &unknown;");
    }

    #[test]
    fn srt_collapses_blank_lines_inside_cue_text() {
        let out = render(&[seg(1, 0.0, 2.0, "Line one\n\nLine two"), seg(2, 2.0, 4.0, "Second cue")], Format::Srt);
        let cues: Vec<&str> = out.split("\n\n").filter(|c| !c.trim().is_empty()).collect();
        assert_eq!(cues.len(), 2);
        assert!(cues[0].contains("Line one\nLine two"));
    }

    #[test]
    fn srt_matches_macos_layout() {
        let out = render(&[seg(1, 0.5, 2.25, "Hello"), seg(2, 3661.0, 3662.5, "World")], Format::Srt);
        assert_eq!(out, "1\n00:00:00,500 --> 00:00:02,250\nHello\n\n2\n01:01:01,000 --> 01:01:02,500\nWorld\n");
    }

    #[test]
    fn vtt_output() {
        let out = render(&[seg(1, 0.5, 2.25, "Hello"), seg(2, 3661.0, 3662.5, "World")], Format::Vtt);
        assert!(out.starts_with("WEBVTT\n\n"));
        assert!(out.contains("00:00:00.500 --> 00:00:02.250"));
        assert!(out.contains("01:01:01.000 --> 01:01:02.500"));
    }

    #[test]
    fn timestamp_rollover_and_bad_values() {
        assert_eq!(format_srt_timestamp(2.9996), "00:00:03,000");
        assert_eq!(format_srt_timestamp(1.0599), "00:00:01,060");
        assert_eq!(format_srt_timestamp(f64::INFINITY), "99:59:59,999");
        assert_eq!(format_srt_timestamp(f64::NAN), "00:00:00,000");
        assert_eq!(format_srt_timestamp(-3.0), "00:00:00,000");
        assert_eq!(format_display_timestamp(f64::NAN), "00:00:00");
        assert_eq!(format_display_timestamp(f64::NEG_INFINITY), "00:00:00");
    }

    #[test]
    fn text_and_markdown() {
        let segs = [seg(1, 0.0, 61.0, "One\nTwo"), seg(2, 61.0, 62.0, "  ")];
        assert_eq!(render(&segs, Format::Text), "One\nTwo\n");
        assert_eq!(render(&segs[..1], Format::Markdown), "- `00:00:00 - 00:01:01` One / Two\n");
    }

    #[test]
    fn write_file_is_atomic_and_readable() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("out.srt");
        write_file(&[seg(1, 0.0, 1.0, "Hi")], Format::Srt, &path).unwrap();
        assert_eq!(std::fs::read_to_string(&path).unwrap(), "1\n00:00:00,000 --> 00:00:01,000\nHi\n");
        assert_eq!(std::fs::read_dir(dir.path()).unwrap().count(), 1);
    }
}
