//! Subtitle export and import. Ports `SubtitleWriter` and `SubtitleReader`.

mod intro;
mod reader;
mod writer;

pub use intro::{intro_cue_texts, segments_prepending_intro};
pub use reader::{
    decode_bytes, parse, parse_document, parse_timestamp, read_file, DecodedText, ParsedDocument, ReadError, MAX_FILE_SIZE,
    MAX_TIMESTAMP_SECONDS,
};
pub use writer::{
    format_display_timestamp, format_srt_timestamp, format_vtt_timestamp, plain_cue_text, render, sanitized_cue_text, write_file,
};

use std::path::Path;

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum Format {
    Srt,
    Vtt,
    Text,
    Markdown,
    Json,
}

impl Format {
    pub const ALL: [Format; 5] = [Format::Srt, Format::Vtt, Format::Text, Format::Markdown, Format::Json];

    pub fn extension(self) -> &'static str {
        match self {
            Format::Srt => "srt",
            Format::Vtt => "vtt",
            Format::Text => "txt",
            Format::Markdown => "md",
            Format::Json => "json",
        }
    }

    pub fn label(self) -> &'static str {
        match self {
            Format::Srt => "SRT",
            Format::Vtt => "WebVTT",
            Format::Text => "Plain Text",
            Format::Markdown => "Markdown",
            Format::Json => "JSON",
        }
    }

    /// Accepts the extension or the macOS raw value (`text`, `markdown`).
    pub fn parse(name: &str) -> Option<Format> {
        match name.trim().to_ascii_lowercase().as_str() {
            "srt" => Some(Format::Srt),
            "vtt" | "webvtt" => Some(Format::Vtt),
            "txt" | "text" => Some(Format::Text),
            "md" | "markdown" => Some(Format::Markdown),
            "json" => Some(Format::Json),
            _ => None,
        }
    }

    /// Only SRT and WebVTT can be imported.
    pub fn importable_from(path: &Path) -> Option<Format> {
        match path.extension()?.to_str()?.to_ascii_lowercase().as_str() {
            "srt" => Some(Format::Srt),
            "vtt" => Some(Format::Vtt),
            _ => None,
        }
    }
}
