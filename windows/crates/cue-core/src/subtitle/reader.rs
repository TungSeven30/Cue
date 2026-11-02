use super::{sanitized_cue_text, Format};
use crate::segment::Segment;
use regex::Regex;
use std::path::Path;
use std::sync::LazyLock;
use unicode_normalization::UnicodeNormalization;

/// A 20 MB "subtitle" is a mislabeled video; refuse it rather than read it.
pub const MAX_FILE_SIZE: u64 = 20 * 1024 * 1024;
/// 100 hours: longer than any real media, short enough to reject junk.
const MAX_TIMESTAMP_SECONDS: f64 = 100.0 * 3600.0;

#[derive(Debug, Clone, PartialEq, thiserror::Error)]
pub enum ReadError {
    #[error("The file could not be read as text.")]
    Unreadable,
    #[error("{} can't be loaded. Choose an SRT or WebVTT subtitle file.", if .0.is_empty() { "That kind of file".to_string() } else { format!("\".{}\" files", .0) })]
    UnsupportedFormat(String),
    #[error("The file contains no subtitle cues.")]
    NoCues,
    #[error("The file is {:.1} MB, past the 20 MB limit for subtitle files.", *.0 as f64 / 1_048_576.0)]
    TooLarge(u64),
}

pub struct DecodedText {
    pub text: String,
    /// True when the bytes were not Unicode and the encoding was guessed
    /// (Windows-1258 or Windows-1252); callers should not write back to the
    /// source until a person has looked at it.
    pub requires_encoding_review: bool,
}

pub struct ParsedDocument {
    pub segments: Vec<Segment>,
    /// The file had content this model cannot represent (VTT regions/styles,
    /// overlapping timing lines, empty cues), so re-saving would lose it.
    pub has_unrepresented_content: bool,
}

/// Read and parse an `.srt` or `.vtt` file.
pub fn read_file(path: &Path, max_size: u64) -> Result<(ParsedDocument, DecodedText), ReadError> {
    let ext = path.extension().and_then(|e| e.to_str()).unwrap_or("").to_ascii_lowercase();
    let format = Format::importable_from(path).ok_or(ReadError::UnsupportedFormat(ext))?;
    // A size we cannot read fails the cap rather than bypassing it.
    let size = std::fs::metadata(path).map(|m| m.len()).unwrap_or(u64::MAX);
    if size > max_size {
        return Err(ReadError::TooLarge(size));
    }
    let bytes = std::fs::read(path).map_err(|_| ReadError::Unreadable)?;
    let decoded = decode_bytes(&bytes).ok_or(ReadError::Unreadable)?;
    let doc = parse_document(&decoded.text, format)?;
    Ok((doc, decoded))
}

static VIETNAMESE_TONE: LazyLock<Regex> =
    LazyLock::new(|| Regex::new("[aăâeêioôơuưyAĂÂEÊIOÔƠUƯY][\u{0300}\u{0301}\u{0303}\u{0309}\u{0323}]").unwrap());

/// UTF-16 with BOM, then UTF-8, then Windows-1258 when it yields Vietnamese
/// tone marks, then Windows-1252. SRT files in the wild are often legacy
/// encoded, so a UTF-8 failure must not end the attempt.
pub fn decode_bytes(bytes: &[u8]) -> Option<DecodedText> {
    let strip = |s: String| s.strip_prefix('\u{FEFF}').map(str::to_string).unwrap_or(s);
    if bytes.len() >= 2 && (bytes[..2] == [0xFF, 0xFE] || bytes[..2] == [0xFE, 0xFF]) {
        let enc = if bytes[0] == 0xFF { encoding_rs::UTF_16LE } else { encoding_rs::UTF_16BE };
        let (text, _, had_errors) = enc.decode(bytes);
        return (!had_errors).then(|| DecodedText { text: strip(text.into_owned()), requires_encoding_review: false });
    }
    if let Ok(text) = std::str::from_utf8(bytes) {
        return Some(DecodedText { text: strip(text.to_string()), requires_encoding_review: false });
    }
    let (vn, _, vn_errors) = encoding_rs::WINDOWS_1258.decode(bytes);
    if !vn_errors && VIETNAMESE_TONE.is_match(&vn) {
        return Some(DecodedText { text: vn.nfc().collect(), requires_encoding_review: true });
    }
    let (western, _, _) = encoding_rs::WINDOWS_1252.decode(bytes);
    Some(DecodedText { text: strip(western.into_owned()), requires_encoding_review: true })
}

pub fn parse(text: &str, format: Format) -> Result<Vec<Segment>, ReadError> {
    parse_document(text, format).map(|d| d.segments)
}

static BLANKISH_LINE: LazyLock<Regex> = LazyLock::new(|| Regex::new("\n[ \t]+\n").unwrap());

pub fn parse_document(text: &str, format: Format) -> Result<ParsedDocument, ReadError> {
    let mut normalized = text.replace("\r\n", "\n").replace('\r', "\n");
    // Separator lines carrying a space or tab (OCR tools) must still split
    // cues. Loop because adjacent matches share their newline.
    while BLANKISH_LINE.is_match(&normalized) {
        normalized = BLANKISH_LINE.replace_all(&normalized, "\n\n").into_owned();
    }

    let mut segments: Vec<Segment> = Vec::new();
    let mut unrepresented = false;
    for block in normalized.split("\n\n") {
        let lines: Vec<&str> = block.split('\n').filter(|l| !l.trim_matches([' ', '\t']).is_empty()).collect();
        let Some(first) = lines.first() else { continue };
        if format == Format::Vtt && is_vtt_metadata(first) {
            if !first.starts_with("WEBVTT") {
                unrepresented = true;
            }
            continue;
        }
        // Malformed blocks are skipped: losing the whole file to one bad cue is worse.
        let timings: Vec<(usize, (f64, f64))> =
            lines.iter().enumerate().filter(|(_, l)| l.contains("-->")).filter_map(|(i, l)| parse_timing_line(l).map(|t| (i, t))).collect();
        if timings.is_empty() {
            unrepresented = true;
            continue;
        }
        if timings.len() > 1 {
            unrepresented = true;
        }
        for (pos, &(timing_index, (start, end))) in timings.iter().enumerate() {
            let mut body_end = timings.get(pos + 1).map(|t| t.0).unwrap_or(lines.len());
            if body_end < lines.len() && body_end > timing_index + 1 && lines[body_end - 1].trim().parse::<i64>().is_ok() {
                body_end -= 1;
            }
            let body = lines[timing_index + 1..body_end].join("\n");
            let cleaned = sanitized_cue_text(&body);
            if cleaned.is_empty() {
                unrepresented = true;
                continue;
            }
            let end_tokens = lines[timing_index].rsplit("-->").next().map(|s| s.split_whitespace().count()).unwrap_or(0);
            if end_tokens > 1 || end < start || (timing_index > 0 && lines[timing_index - 1].trim().parse::<i64>().is_err()) {
                unrepresented = true;
            }
            segments.push(Segment::new(segments.len() as i64 + 1, start, end.max(start), cleaned));
        }
    }
    if segments.is_empty() {
        return Err(ReadError::NoCues);
    }
    Ok(ParsedDocument { segments, has_unrepresented_content: unrepresented })
}

fn is_vtt_metadata(line: &str) -> bool {
    ["WEBVTT", "NOTE", "STYLE", "REGION"]
        .iter()
        .any(|k| line == *k || line.strip_prefix(k).is_some_and(|rest| rest.starts_with(' ') || rest.starts_with('\t')))
}

fn parse_timing_line(line: &str) -> Option<(f64, f64)> {
    let parts: Vec<&str> = line.split("-->").collect();
    if parts.len() != 2 {
        return None;
    }
    // Trailing VTT cue settings or legacy SRT coordinates follow the end time.
    let end_token = parts[1].split_whitespace().next().unwrap_or("");
    Some((parse_timestamp(parts[0].trim_matches([' ', '\t']))?, parse_timestamp(end_token)?))
}

/// `HH:MM:SS,mmm`, `HH:MM:SS.mmm` and `MM:SS.mmm`.
pub fn parse_timestamp(token: &str) -> Option<f64> {
    let normalized = token.replace(',', ".");
    let pieces: Vec<&str> = normalized.split(':').collect();
    if !(2..=3).contains(&pieces.len()) {
        return None;
    }
    let num = |s: &str| -> Option<f64> {
        // Reject inf/nan spellings outright, as well as anything non-numeric.
        if s.is_empty() || s.chars().any(|c| c.is_ascii_alphabetic() && c != 'e' && c != 'E') {
            return None;
        }
        s.parse::<f64>().ok()
    };
    let mut seconds = 0.0;
    for piece in &pieces[..pieces.len() - 1] {
        seconds = seconds * 60.0 + num(piece)?;
    }
    let total = seconds * 60.0 + num(pieces[pieces.len() - 1])?;
    (0.0..MAX_TIMESTAMP_SECONDS).contains(&total).then_some(total)
}

#[cfg(test)]
mod tests {
    use super::super::render;
    use super::*;

    fn texts(segs: &[Segment]) -> Vec<&str> {
        segs.iter().map(|s| s.text.as_str()).collect()
    }

    #[test]
    fn vtt_tabs_and_keyword_prefixed_identifiers_retain_cues() {
        for fixture in ["WEBVTT\n\n00:00.000 --> 00:02.000\talign:start\nHello\n", "WEBVTT\n\nNOTEBOOK\n00:00.000 --> 00:02.000\nHello\n"] {
            assert_eq!(parse(fixture, Format::Vtt).unwrap()[0].text, "Hello");
        }
    }

    #[test]
    fn missing_srt_separator_does_not_swallow_next_cue() {
        let srt = "1\n00:00:00,000 --> 00:00:01,000\nHello\n2\n00:00:02,000 --> 00:00:03,000\nWorld\n";
        assert_eq!(texts(&parse(srt, Format::Srt).unwrap()), ["Hello", "World"]);
    }

    #[test]
    fn decodes_vietnamese_1258_utf8_and_latin1() {
        assert_eq!(decode_bytes(&[86, 105, 234, 242, 116]).unwrap().text, "Việt");
        assert_eq!(decode_bytes("Tiếng Việt — 日本語".as_bytes()).unwrap().text, "Tiếng Việt — 日本語");
        assert_eq!(decode_bytes(&[67, 97, 102, 233]).unwrap().text, "Café");
    }

    #[test]
    fn decodes_utf16_with_bom() {
        let mut le = vec![0xFF, 0xFE];
        le.extend("Hello\nWorld".encode_utf16().flat_map(u16::to_le_bytes));
        assert_eq!(decode_bytes(&le).unwrap().text, "Hello\nWorld");
        let mut be = vec![0xFE, 0xFF];
        be.extend("Hello\nWorld".encode_utf16().flat_map(u16::to_be_bytes));
        assert_eq!(decode_bytes(&be).unwrap().text, "Hello\nWorld");
    }

    #[test]
    fn renumbers_and_parses_standard_srt() {
        let srt = "5\n00:00:01,000 --> 00:00:02,500\nHello there\n\n5\n00:00:03,000 --> 00:00:04,000\nSecond\n\n2\n00:00:05,000 --> 00:00:06,000\nThird";
        let segs = parse(srt, Format::Srt).unwrap();
        assert_eq!(segs.iter().map(|s| s.id).collect::<Vec<_>>(), [1, 2, 3]);
        assert_eq!((segs[0].start, segs[0].end), (1.0, 2.5));
    }

    #[test]
    fn timestamps() {
        assert_eq!(parse_timestamp("00:00:01,500"), Some(1.5));
        assert_eq!(parse_timestamp("00:00:01.500"), Some(1.5));
        assert_eq!(parse_timestamp("01:02.500"), Some(62.5));
        assert_eq!(parse_timestamp("01:01:01,000"), Some(3661.0));
        assert_eq!(parse_timestamp("nonsense"), None);
        for bad in ["00:00:inf", "00:nan:00,000", "00:00:1e400", "999999999:00:00,000", "00:00:-05,000"] {
            assert_eq!(parse_timestamp(bad), None, "{bad}");
        }
        assert!(parse_timestamp("99:59:59,999").is_some());
    }

    #[test]
    fn vtt_skips_header_and_notes() {
        let vtt = "WEBVTT\n\nNOTE this is a note\n\n00:00:01.000 --> 00:00:02.000\nHello\n";
        let doc = parse_document(vtt, Format::Vtt).unwrap();
        assert_eq!(texts(&doc.segments), ["Hello"]);
        assert!(doc.has_unrepresented_content);
    }

    #[test]
    fn skips_malformed_block_and_arrow_in_text_stays() {
        let srt = "1\n00:00:01,000 --> 00:00:02,000\nGood\n\ngarbage with no timing at all\n\n2\n00:00:03,000 --> 00:00:04,000\nAlso good";
        assert_eq!(texts(&parse(srt, Format::Srt).unwrap()), ["Good", "Also good"]);
        let arrow = "1\n00:00:01,000 --> 00:00:02,000\nstep one --> step two";
        assert_eq!(texts(&parse(arrow, Format::Srt).unwrap()), ["step one --> step two"]);
    }

    #[test]
    fn splits_on_whitespace_bearing_separator_lines() {
        let srt = "1\n00:00:01,000 --> 00:00:02,000\nA\n \n2\n00:00:03,000 --> 00:00:04,000\nB\n\t\n3\n00:00:05,000 --> 00:00:06,000\nC";
        let segs = parse(srt, Format::Srt).unwrap();
        assert_eq!(texts(&segs), ["A", "B", "C"]);
        assert_eq!(segs.iter().map(|s| s.start).collect::<Vec<_>>(), [1.0, 3.0, 5.0]);
    }

    #[test]
    fn preserves_inline_markup_and_rejects_empty() {
        let srt = "1\n00:00:01,000 --> 00:00:02,000\n<i>Italics</i> and {\\an8}position";
        assert_eq!(parse(srt, Format::Srt).unwrap()[0].text, "<i>Italics</i> and {\\an8}position");
        assert_eq!(parse("", Format::Srt).unwrap_err(), ReadError::NoCues);
    }

    #[test]
    fn round_trips_through_writer() {
        let original = vec![Segment::new(1, 0.5, 2.25, "Hello"), Segment::new(2, 3661.0, 3662.5, "Two\nlines")];
        for f in [Format::Srt, Format::Vtt] {
            assert_eq!(parse(&render(&original, f), f).unwrap(), original, "{}", f.label());
        }
    }

    #[test]
    fn file_size_cap_and_unsupported_extension() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("a.srt");
        std::fs::write(&path, "1\n00:00:01,000 --> 00:00:02,000\nHi\n").unwrap();
        assert!(matches!(read_file(&path, 10), Err(ReadError::TooLarge(_))));
        assert_eq!(read_file(&path, 1024).unwrap().0.segments.len(), 1);
        let ass = dir.path().join("a.ass");
        std::fs::write(&ass, "x").unwrap();
        assert_eq!(read_file(&ass, 1024).err(), Some(ReadError::UnsupportedFormat("ass".into())));
    }
}
